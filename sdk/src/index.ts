/**
 * @kach/sdk - Type-safe TypeScript SDK for Kach Protocol
 *
 * Auto-generated from Move contracts using Aptos Surf
 *
 * @example
 * ```typescript
 * import { createKachClient, Tranche, RepaymentStatus } from "@kach/sdk";
 * import { Account, Network } from "@aptos-labs/ts-sdk";
 *
 * // Create client
 * const client = createKachClient({ network: Network.TESTNET });
 *
 * // View functions (read-only)
 * const score = await client.view.trust_score.get_trust_score({
 *   functionArguments: ["0xborrower...", "0xgovernance..."],
 *   typeArguments: [],
 * });
 *
 * // Entry functions (transactions)
 * const admin = Account.generate();
 * await client.entry.trust_score.initialize_trust_score({
 *   account: admin,
 *   functionArguments: ["0xnewborrower...", "500000"],
 *   typeArguments: [],
 * });
 * ```
 */

// biome-ignore lint/performance/noBarrelFile: This is a library
export { KACH_ABI, KACH_MODULE_ADDRESS } from "../generated/abi";
export {
  createKachClient,
  type KachClient,
  type KachClientConfig,
} from "./client";
