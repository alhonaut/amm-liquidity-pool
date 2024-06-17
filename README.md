# Automated Market Maker Liquidity Pool

This repository contains an Automated Market Maker (AMM) Liquidity Pool implementation designed for decentralized exchanges on the Aptos blockchain.

## Features

- **AMM Functionality**: Facilitates automated trading between cryptocurrency pairs.
- **Liquidity Pool**: Users can contribute to liquidity pools and earn fees from trades.
- **Aptos Integration**: Specifically designed to work with the Aptos blockchain.
- **Custom Fee Structure**: Allows configuring different fee structures for trades.
- **Efficient Algorithms**: Uses efficient algorithms for trade execution and liquidity management.

## Getting Started

### Prerequisites

- [Aptos CLI](https://aptos.dev/cli-tools/aptos-cli/)
- Move Language support

### Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/alhonaut/amm-liquidity-pool.git
   cd amm-liquidity-pool
2. Build and deploy the contract:
   ```bash
   aptos move compile
   aptos move publish

## Usage
### Adding Liquidity
To add liquidity, call the `add_liquidit`y function with the appropriate parameters. Ensure you specify the token pair and the amounts to be added.

### Removing Liquidity
To remove liquidity, call the `remove_liquidity` function. You need to specify the liquidity token amount to be removed.

### Swapping Tokens
To swap tokens, call the `swap` function specifying the input and output token types and amounts. Ensure you check the slippage and set appropriate limits.

## Testing

### Prerequisites
- Move unit testing framework

### Running Tests
1. Navigate to the project directory:
   ```bash
   cd amm-liquidity-pool
2. Run the tests:
   ```bash
   aptos move test
3. Check the coverage report:
   ```bash
   aptos move test --coverage

## Writing Tests
- Create test cases in the tests directory.
- Ensure each function has corresponding unit tests.
- Use mock data for testing edge cases and performance.

## Acknowledgements
- Thanks to the Aptos and Overmind community for their support and contributions.
- Inspired by various decentralized exchange protocols.
