set dotenv-load
set positional-arguments

# List available recipes
default:
  @just --list

# ------------------------------------ General ------------------------------------

# Delete all git branches except for main
clean-branches:
  git branch | grep -v -E "(main)" | xargs git branch -D

# Format project
format:
  # todo

# Run tests
test:
  # todo

# ------------------------------------ Docs ------------------------------------

# Run docs
[group: 'docs']
[working-directory: 'docs']
docs-start:
	bun --bun run dev

# ------------------------------------ Contracts ------------------------------------

# Compile Move contracts
[group: 'contracts']
contracts-compile:
	aptos move compile --dev --save-metadata

# Deploy contracts to localnet
[group: 'contracts']
contracts-deploy:
	aptos move publish --profile default --dev --assume-yes --included-artifacts none --max-gas 20000

# ------------------------------------ Localnet ------------------------------------

# Start local Aptos testnet with faucet
[group: 'localnet']
localnet-start:
	aptos node run-local-testnet --with-faucet

# Fund default account on localnet
[group: 'localnet']
localnet-fund:
	aptos account fund-with-faucet --account default --amount 100000000

# ------------------------------------ SDK ------------------------------------

# Fetch ABI from deployed contracts
[group: 'sdk']
[working-directory: 'sdk']
sdk-abi-fetch:
	bun scripts/fetch-abi.ts

# Generate SDK types (alias for abi-fetch)
[group: 'sdk']
[working-directory: 'sdk']
sdk-generate:
	bun scripts/fetch-abi.ts

# Build SDK
[group: 'sdk']
[working-directory: 'sdk']
sdk-build:
	tsc

# Build SDK in watch mode
[group: 'sdk']
[working-directory: 'sdk']
sdk-dev:
	tsc --watch

# Full SDK setup: generate types and build
[group: 'sdk']
[working-directory: 'sdk']
sdk-prepare:
	bun scripts/fetch-abi.ts && tsc
