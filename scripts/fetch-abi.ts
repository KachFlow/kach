#!/usr/bin/env tsx
/**
 * Fetch ABI from deployed Kach contracts
 *
 * Usage:
 *   # From localnet (default)
 *   npm run abi:fetch
 *
 *   # From custom network
 *   NETWORK=testnet MODULE_ADDRESS=0x123... npm run abi:fetch
 *
 *   # From custom fullnode
 *   FULLNODE_URL=http://localhost:8080 MODULE_ADDRESS=0x123... npm run abi:fetch
 */

import { Aptos, AptosConfig, Network } from "@aptos-labs/ts-sdk";
import fs from "fs";
import path from "path";

// Configuration from environment
const NETWORK = (process.env.NETWORK as Network) || Network.LOCAL;
const FULLNODE_URL = process.env.FULLNODE_URL;
const MODULE_ADDRESS = process.env.MODULE_ADDRESS || getDefaultAddress();

function getDefaultAddress(): string {
  // Try to read from .aptos/config.yaml default profile
  try {
    const configPath = path.join(process.cwd(), ".aptos", "config.yaml");
    if (fs.existsSync(configPath)) {
      const config = fs.readFileSync(configPath, "utf-8");
      // Simple regex to extract default profile address
      const match = config.match(/account:\s*([a-fA-F0-9x]+)/);
      if (match) {
        return match[1];
      }
    }
  } catch (e) {
    // Ignore errors, will prompt user
  }

  return "";
}

async function fetchABI() {
  console.log("🔍 Fetching ABI from Aptos network...\n");

  if (!MODULE_ADDRESS) {
    console.error("❌ MODULE_ADDRESS not provided!");
    console.error("\nPlease set MODULE_ADDRESS environment variable:");
    console.error("  export MODULE_ADDRESS=0x123...");
    console.error("\nOr deploy contracts first:");
    console.error("  npm run contracts:deploy");
    process.exit(1);
  }

  console.log(`📍 Module Address: ${MODULE_ADDRESS}`);
  console.log(`🌐 Network: ${FULLNODE_URL || NETWORK}\n`);

  // Create Aptos client
  const config = FULLNODE_URL
    ? new AptosConfig({ fullnode: FULLNODE_URL })
    : new AptosConfig({ network: NETWORK });

  const aptos = new Aptos(config);

  try {
    // Fetch account modules
    console.log("⏳ Fetching modules from chain...");
    const modules = await aptos.getAccountModules({
      accountAddress: MODULE_ADDRESS,
    });

    console.log(`✅ Found ${modules.length} modules\n`);

    // List modules found
    console.log("📦 Modules:");
    modules.forEach((module) => {
      console.log(`   - ${module.abi?.name}`);
    });
    console.log();

    // Extract ABIs
    const abis = modules.map((module) => module.abi);

    // Generate TypeScript file
    const output = `// Auto-generated ABI from Aptos network
// Module Address: ${MODULE_ADDRESS}
// Network: ${FULLNODE_URL || NETWORK}
// Generated: ${new Date().toISOString()}

export const KACH_MODULE_ADDRESS = "${MODULE_ADDRESS}" as const;

export const KACH_ABI = ${JSON.stringify(abis, null, 2)} as const;
`;

    // Ensure generated directory exists
    const generatedDir = path.join(process.cwd(), "sdk", "src", "generated");
    if (!fs.existsSync(generatedDir)) {
      fs.mkdirSync(generatedDir, { recursive: true });
    }

    // Write to file
    const outputPath = path.join(generatedDir, "abi.ts");
    fs.writeFileSync(outputPath, output);

    console.log(`✅ ABI saved to: ${path.relative(process.cwd(), outputPath)}`);
    console.log("\n🎉 SDK generation complete!");
    console.log("\n💡 Next steps:");
    console.log("   cd sdk");
    console.log("   bun install");
    console.log("   bun run build");

  } catch (error) {
    console.error("\n❌ Error fetching ABI:");
    if (error instanceof Error) {
      console.error(`   ${error.message}`);
    } else {
      console.error(error);
    }
    console.error("\n💡 Make sure:");
    console.error("   1. Contracts are deployed to the network");
    console.error("   2. MODULE_ADDRESS is correct");
    console.error("   3. Network/fullnode is accessible");
    process.exit(1);
  }
}

fetchABI().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
