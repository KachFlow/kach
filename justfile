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
	aptos move compile --dev --save-metadata --named-addresses kach=default

# Deploy contracts to localnet
[group: 'contracts']
contracts-deploy:
	aptos move publish --dev --assume-yes --included-artifacts none --max-gas 100000 --named-addresses kach=default

# ------------------------------------ Localnet ------------------------------------

# Start local Aptos testnet with faucet
[group: 'localnet']
localnet-start:
	aptos node run-local-testnet --with-faucet

# Fund default account on localnet
[group: 'localnet']
localnet-fund:
	aptos account fund-with-faucet --account default --amount 100000000

# Deploy contracts to localnet (compile, fund, deploy)
[group: 'localnet']
localnet-deploy:
	#!/usr/bin/env bash
	set -e
	echo "🚀 Deploying Kach contracts to localnet..."
	echo ""

	# Check if localnet is running
	echo "📡 Checking if localnet is running..."
	if ! curl -s http://localhost:8080/v1 > /dev/null 2>&1; then
	    echo "❌ Localnet is not running!"
	    echo ""
	    echo "Please start localnet in another terminal:"
	    echo "  just localnet-start"
	    exit 1
	fi
	echo "✅ Localnet is running"
	echo ""

	# Fund the account
	echo "💰 Funding default account..."
	aptos account fund-with-faucet --account default --amount 100000000 || {
	    echo "⚠️  Funding failed - account may already be funded"
	}
	echo ""

	# Check balance
	echo "💳 Checking account balance..."
	aptos account list --profile default
	echo ""

	# Compile contracts
	echo "🔨 Compiling contracts..."
	just contracts-compile
	echo ""

	# Publish contracts
	echo "📦 Publishing contracts..."
	just contracts-deploy

	echo ""
	echo "✅ Deployment complete!"
	echo ""
	echo "📍 Module Address: Use the 'sender' address from above"

# ------------------------------------ SDK ------------------------------------

# Generate SDK types (alias for abi-fetch)
[group: 'sdk']
[working-directory: 'sdk']
sdk-generate:
	bun scripts/fetch-abi.ts
