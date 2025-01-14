import React from 'react';
import styled from 'styled-components';

interface CustomTableProps {
  headers: string[];
  data: any[][];
  onRowClick?: (rowData: any[]) => void;
  selectedRow?: number;
}

export const CustomTable: React.FC<CustomTableProps> = ({ headers, data, onRowClick, selectedRow }) => {
  return (
    <TableContainer>
      <StyledTable>
        <thead>
          <tr>
            {headers.map((header, index) => (
              <TableHeader key={index}>{header}</TableHeader>
            ))}
          </tr>
        </thead>
        <tbody>
          {data.map((row, rowIndex) => (
            <TableRow key={rowIndex} onClick={() => onRowClick && onRowClick([rowIndex])} selected={rowIndex === selectedRow}>
              {row.map((cell, cellIndex) => (
                <TableCell key={cellIndex}>{cell}</TableCell>
              ))}
            </TableRow>
          ))}
        </tbody>
      </StyledTable>
    </TableContainer>
  );
};

const TableContainer = styled.div`
  width: 100%;
  overflow-x: auto;
`;

const StyledTable = styled.table`
  width: 100%;
  border-collapse: collapse;
  background: rgba(0, 0, 0, 0.3);
  border-radius: 4px;
`;

const TableHeader = styled.th`
  color: rgba(255, 255, 255, 0.8);
  padding: 16px;
  text-align: left;
  border-bottom: 1px solid rgba(255, 255, 255, 0.3);
`;

const TableRow = styled.tr<{ selected: boolean }>`
  &:nth-child(even) {
    background-color: rgba(0, 0, 0, 0.1);
  }
  ${({ selected }) => selected && `
    border: 2px solid rgba(255, 255, 255, 0.8);
    box-shadow: none;
  `}
  ${({ selected }) => !selected && `
    &:hover {
      border: 2px solid rgba(255, 255, 255, 0.8);
      box-shadow: none;
    }
  `}
`;

const TableCell = styled.td`
  padding: 16px;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
`;
