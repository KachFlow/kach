# Kach Protocol

A decentralized lending protocol on Aptos with integrated trust scoring and flexible tranche-based risk management.

## Features

Kach Protocol provides a complete lending infrastructure with:

- **Trust Scoring**: On-chain credit scoring for borrowers based on repayment history and protocol participation
- **Risk Tranches**: Multi-level risk segmentation for lenders with different risk appetites
- **Position NFTs**: Tradeable NFT positions for lenders
- **Interest Rate Models**: Dynamic interest rates based on pool utilization
- **Governance**: Protocol parameter management and upgradability

## Installation

```bash
npm install @kachflow/sdk @aptos-labs/ts-sdk
```

## Quick Start

```typescript
import { createKachClient } from "@kachflow/sdk";
import { Account, Network } from "@aptos-labs/ts-sdk";

// Connect to the network
const client = createKachClient({
  network: Network.TESTNET
});

// Read trust score for a borrower
const score = await client.view.trust_score.get_trust_score({
  functionArguments: [borrowerAddress, governanceAddress],
  typeArguments: [],
});

console.log("Trust score:", score);

// Create a new pool (requires admin account)
const admin = Account.generate();

await client.entry.pool.create_pool({
  account: admin,
  functionArguments: [
    poolName,
    maxLoanAmount,
    minLoanDuration,
    maxLoanDuration
  ],
  typeArguments: ["0x1::aptos_coin::AptosCoin"],
});
```

## Repository Structure

```
.
├── sources/           # Move smart contracts
│   ├── pool.move
│   ├── trust_score.move
│   ├── tranche.move
│   ├── credit_engine.move
│   └── ...
├── sdk/              # TypeScript SDK
│   ├── src/
│   ├── scripts/      # ABI generation scripts
│   └── generated/    # Auto-generated ABI
├── docs/             # Protocol documentation site
└── build/            # Compiled Move bytecode
```

### Move Contracts

The protocol is implemented as a collection of Move modules:

- **pool**: Core lending pool logic with deposit and borrow functions
- **trust_score**: Credit scoring system tracking borrower behavior
- **tranche**: Risk-based tranches for lender capital segmentation
- **credit_engine**: Credit line management and utilization tracking
- **interest_rate**: Dynamic interest rate calculations
- **position_nft**: NFT representations of lender positions
- **governance**: Protocol administration and parameter updates
- **attestator**: Third-party attestation integration
- **prt**: Payment Receivable Token for borrower obligations

### TypeScript SDK

The SDK provides full type-safety for all protocol interactions:

- Auto-generated from deployed Move contracts
- Complete TypeScript types for all functions
- Supports both view (read) and entry (write) functions
- Built with [Thala Surf](https://github.com/ThalaLabs/surf) for type inference

## Development

### Prerequisites

- [Aptos CLI](https://aptos.dev/tools/aptos-cli/)
- [Bun](https://bun.sh/) or Node.js
- [Just](https://github.com/casey/just) (optional, for task automation)

### Compile Move Contracts

```bash
aptos move compile --named-addresses kach=default
```

Or using just:

```bash
just contracts-compile
```

### Run Local Testnet

Start a local Aptos node with faucet:

```bash
aptos node run-local-testnet --with-faucet
```

Or using just:

```bash
just localnet-start
```

### Deploy to Localnet

```bash
just localnet-deploy
```

This will:
1. Check if localnet is running
2. Fund the default account
3. Compile contracts
4. Deploy to localnet

### Generate SDK

After deploying contracts, generate the TypeScript SDK:

```bash
cd sdk
bun install
bun scripts/fetch-abi.ts
```

Or using just:

```bash
just sdk-generate
```

This fetches the ABI from the deployed contract and generates TypeScript types.

### Build SDK

```bash
cd sdk
bun run build
```

The compiled SDK will be output to `sdk/dist/`.

## License

MIT
