pragma solidity ^0.8.12;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Verifier } from "./Verifier.sol";

contract Ramp is Verifier {
    
    /* ============ Enums ============ */

    enum OrderStatus {
        Unopened,
        Open,
        Filled,
        Canceled
    }

    enum ClaimStatus {
        Unsubmitted,
        Submitted,
        Used,
        Clawback
    }
    
    /* ============ Structs ============ */

    struct Order {
        address onRamper;
        uint256 amountToReceive;
        uint256 maxAmountToPay;
        OrderStatus status;
        address[] claimers;  
    }

    struct OrderClaim {
        uint256 venmoId;
        ClaimStatus status;
        uint256 claimExpirationTime;
    }

    struct OrderWithId {
        uint256 id;
        address onRamper;
        uint256 amountToReceive;
        uint256 maxAmountToPay;
        OrderStatus status;
        address[] claimers;  
    }

    /* ============ Modifiers ============ */

    modifier onlyRegisteredUser() {
        require(userToVenmoId[msg.sender] != 0, "User is not registered");
        _;
    }

    /* ============ Public Variables ============ */

    uint256 public constant rsaModulusChunksLen = 17;
    uint16 public constant bodyLen = 9;
    uint16 public constant msgLen = 26;
    uint16 public constant bytesInPackedBytes = 7;  // 7 bytes in a packed item returned from circom

    /* ============ Public Variables ============ */

    IERC20 public immutable usdc;
    uint256[rsaModulusChunksLen] public venmoMailserverKeys;

    uint256 public orderNonce;
    mapping(address=>uint256) public userToVenmoId;
    mapping(uint256=>address) public venmoIdToUser;
    mapping(uint256=>Order) public orders;
    mapping(uint256=>mapping(address=>OrderClaim)) public orderClaims;

    /* ============ External Functions ============ */

    constructor(uint256[rsaModulusChunksLen] memory _venmoMailserverKeys, IERC20 _usdc) {
        venmoMailserverKeys = _venmoMailserverKeys;
        usdc = _usdc;

        orderNonce = 1;
    }

    /* ============ External Functions ============ */

    function register(uint256 _venmoId) external {
        require(userToVenmoId[msg.sender] == 0, "User is already registered");
        userToVenmoId[msg.sender] = _venmoId;
        venmoIdToUser[_venmoId] = msg.sender;
    }

    function postOrder(uint256 _amount, uint256 _maxAmountToPay) external onlyRegisteredUser() {
        require(_amount != 0, "Amount can't be 0");
        require(_maxAmountToPay != 0, "Max amount can't be 0");
        
        Order memory order = Order({
            onRamper: msg.sender,
            amountToReceive: _amount,
            maxAmountToPay: _maxAmountToPay,
            status: OrderStatus.Open,
            claimers: new address[](0)
        });

        orders[orderNonce] = order;
        orderNonce++;
    }

    function claimOrder(
        uint256 _orderNonce
    )
        external 
        onlyRegisteredUser()
    {
        require(orders[_orderNonce].status == OrderStatus.Open, "Order has already been filled, canceled, or doesn't exist");
        require(orderClaims[_orderNonce][msg.sender].status == ClaimStatus.Unsubmitted, "Order has already been claimed by caller");
        require(msg.sender != orders[_orderNonce].onRamper, "Can't claim your own order");

        orderClaims[_orderNonce][msg.sender] = OrderClaim({
            venmoId: userToVenmoId[msg.sender],
            status: ClaimStatus.Submitted,
            claimExpirationTime: block.timestamp + 1 days
        });
        orders[_orderNonce].claimers.push(msg.sender);

        usdc.transferFrom(msg.sender, address(this), orders[_orderNonce].amountToReceive);
    }

    function onRamp(
        uint256[2] memory _a,
        uint256[2][2] memory _b,
        uint256[2] memory _c,
        uint256[msgLen] memory _signals
    )
        external
        onlyRegisteredUser()
    {
        // Verify that proof generated by onRamper is valid
        (uint256 onRamperVenmoId, uint256 offRamperVenmoId, uint256 orderId) = _verifyAndParseOnRampProof(_a, _b, _c, _signals);

        // require it is an open order
        require(orders[orderId].status == OrderStatus.Open, "Order has already been filled, canceled, or doesn't exist");

        // Require that the off-ramper has submitted a claim
        address offRamperAddress = venmoIdToUser[offRamperVenmoId];
        require(orderClaims[orderId][offRamperAddress].status == ClaimStatus.Submitted,
            "Claim was never submitted, has been used, or has been clawed back"
        );

        // Require that the on-ramper is the one who fulfilled the venmo request
        require(userToVenmoId[orders[orderId].onRamper] == onRamperVenmoId, "On-ramper venmoId does not match proof");

        orderClaims[orderId][offRamperAddress].status = ClaimStatus.Used;
        orders[orderId].status = OrderStatus.Filled;

        usdc.transfer(orders[orderId].onRamper, orders[orderId].amountToReceive);
    }

    function cancelOrder(uint256 _orderId) external {
        require(orders[_orderId].status == OrderStatus.Open, "Order has already been filled, canceled, or doesn't exist");
        require(msg.sender == orders[_orderId].onRamper, "Only the order creator can cancel it");

        orders[_orderId].status = OrderStatus.Canceled;
    }

    function clawback(uint256 _orderId) external {
        // If a claim was never submitted (Unopened), was used to fill order (Used), or was already clawed back (Clawback) then
        // calling address cannot clawback funds
        require(
            orderClaims[_orderId][msg.sender].status == ClaimStatus.Submitted,
            "Msg.sender has not submitted claim, already clawed back claim, or claim was used to fill order"
        );

        // If order is open then mm can only clawback funds if the claim has expired. For the case where order was cancelled all
        // we need to check is that the claim was not already clawed back (which is done above). Similarly, if the order was filled
        // we only need to check that the caller is not the claimer who's order was used to fill the order (also checked above).
        if (orders[_orderId].status == OrderStatus.Open) {
            require(orderClaims[_orderId][msg.sender].claimExpirationTime < block.timestamp, "Order claim has not expired");
        }

        orderClaims[_orderId][msg.sender].status = ClaimStatus.Clawback;
        usdc.transfer(msg.sender, orders[_orderId].amountToReceive);
    }

    /* ============ View Functions ============ */

    function getClaimsForOrder(uint256 _orderId) external view returns (OrderClaim[] memory) {
        address[] memory claimers = orders[_orderId].claimers;

        OrderClaim[] memory orderClaimsArray = new OrderClaim[](claimers.length);
        for (uint256 i = 0; i < claimers.length; i++) {
            orderClaimsArray[i] = orderClaims[_orderId][claimers[i]];
        }

        return orderClaimsArray;
    }

    function getAllOrders() external view returns (OrderWithId[] memory) {
        OrderWithId[] memory ordersArray = new OrderWithId[](orderNonce - 1);
        for (uint256 i = 1; i < orderNonce; i++) {
            ordersArray[i - 1] = OrderWithId({
                id: i,
                onRamper: orders[i].onRamper,
                amountToReceive: orders[i].amountToReceive,
                maxAmountToPay: orders[i].maxAmountToPay,
                status: orders[i].status,
                claimers: orders[i].claimers
            });
        }

        return ordersArray;
    }

    /* ============ Internal Functions ============ */

    function _verifyAndParseOnRampProof(
        uint256[2] memory a,
        uint256[2][2] memory b,
        uint256[2] memory c,
        uint256[msgLen] memory signals
    )
        internal
        view
        returns (uint256 onRamperVenmoId, uint256 offRamperVenmoId, uint256 orderId)
    {
        // 3 public signals are the masked packed message bytes, 17 are the modulus.
        uint256[3][3] memory bodySignals;
        // bodySignals[0] = onRamperVenmoId, bodySignals[1] = offRamperVenmoId, bodySignals[2] = orderId
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = 0; j < 3; j++) {
                bodySignals[i][j] = signals[i * 3 + j];
            }
        }

        // msg_len-17 public signals are the masked message bytes, 17 are the modulus.
        // Signals: [9:26] -> Modulus, 
        for (uint256 i = bodyLen; i < msgLen - 1; i++) {
            require(signals[i] == venmoMailserverKeys[i - bodyLen], "Invalid: RSA modulus not matched");
        }

        require(verifyProof(a, b, c, signals), "Invalid Proof"); // checks effects iteractions, this should come first

        onRamperVenmoId = _stringToUint256(_convertPackedBytesToBytes(bodySignals[0], bytesInPackedBytes * 3));
        offRamperVenmoId = _stringToUint256(_convertPackedBytesToBytes(bodySignals[1], bytesInPackedBytes * 3));
        orderId = _stringToUint256(_convertPackedBytesToBytes(bodySignals[2], bytesInPackedBytes * 3));
    }

    // Unpacks uint256s into bytes and then extracts the non-zero characters
    // Only extracts contiguous non-zero characters and ensures theres only 1 such state
    // Note that unpackedLen may be more than packedBytes.length * 8 since there may be 0s
    // TODO: Remove console.logs and define this as a pure function instead of a view
    function _convertPackedBytesToBytes(uint256[3] memory packedBytes, uint256 maxBytes) public pure returns (string memory extractedString) {
        uint8 state = 0;
        // bytes: 0 0 0 0 y u s h _ g 0 0 0
        // state: 0 0 0 0 1 1 1 1 1 1 2 2 2
        bytes memory nonzeroBytesArray = new bytes(packedBytes.length * 7);
        uint256 nonzeroBytesArrayIndex = 0;
        for (uint16 i = 0; i < packedBytes.length; i++) {
            uint256 packedByte = packedBytes[i];
            uint8[] memory unpackedBytes = new uint8[](bytesInPackedBytes);
            for (uint j = 0; j < bytesInPackedBytes; j++) {
                unpackedBytes[j] = uint8(packedByte >> (j * 8));
            }

            for (uint256 j = 0; j < bytesInPackedBytes; j++) {
                uint256 unpackedByte = unpackedBytes[j]; //unpackedBytes[j];
                if (unpackedByte != 0) {
                    nonzeroBytesArray[nonzeroBytesArrayIndex] = bytes1(uint8(unpackedByte));
                    nonzeroBytesArrayIndex++;
                    if (state % 2 == 0) {
                        state += 1;
                    }
                } else {
                    if (state % 2 == 1) {
                        state += 1;
                    }
                }
                packedByte = packedByte >> 8;
            }
        }

        string memory returnValue = string(nonzeroBytesArray);
        require(state == 2, "Invalid final state of packed bytes in email");
        // console.log("Characters in username: ", nonzeroBytesArrayIndex);
        require(nonzeroBytesArrayIndex <= maxBytes, "Venmo id too long");
        return returnValue;
        // Have to end at the end of the email -- state cannot be 1 since there should be an email footer
    }

    // Code example:
    function _stringToUint256(string memory s) internal pure returns (uint256) {
        bytes memory b = bytes(s);
        uint256 result = 0;
        uint256 oldResult = 0;

        for (uint i = 0; i < b.length; i++) { // c = b[i] was not needed
            // UNSAFE: Check that the character is a number - we include padding 0s in Venmo ids
            if (uint8(b[i]) >= 48 && uint8(b[i]) <= 57) {
                // store old value so we can check for overflows
                oldResult = result;
                result = result * 10 + (uint8(b[i]) - 48);
                // prevent overflows
                require(result >= oldResult, "Overflow detected");
            }
        }
        return result; 
    }
}
