#!/bin/bash
set -e

echo "🚀 Deploying Kach contracts to localnet..."
echo ""

# Check if localnet is running
echo "📡 Checking if localnet is running..."
if ! curl -s http://localhost:8080/v1 > /dev/null 2>&1; then
    echo "❌ Localnet is not running!"
    echo ""
    echo "Please start localnet in another terminal:"
    echo "  cd sdk && bun run localnet:start"
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
aptos move compile --dev --save-metadata
echo ""

# Publish contracts
echo "📦 Publishing contracts..."
aptos move publish \
    --profile default \
    --dev \
    --assume-yes \
    --included-artifacts none \
    --max-gas 20000

echo ""
echo "✅ Deployment complete!"
echo ""
echo "📍 Module Address: Use the 'sender' address from above"
echo ""
echo "💡 Next steps:"
echo "  1. Copy the module address (sender field)"
echo "  2. export MODULE_ADDRESS=0x..."
echo "  3. cd sdk && bun run generate"
echo "  4. bun run build"
