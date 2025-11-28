import { Aptos, AptosConfig, Network } from "@aptos-labs/ts-sdk";
import { createSurfClient } from "@thalalabs/surf";

import { KACH_ABI, KACH_MODULE_ADDRESS } from "../generated/abi";

/**
 * Configuration options for creating a Kach client
 */
export type KachClientConfig = {
  /** Network to connect to (default: LOCAL) */
  network?: Network;
  /** Custom fullnode URL (overrides network) */
  fullnode?: string;
  /** Custom module address (overrides generated address) */
  moduleAddress?: string;
};

/**
 * Create a fully type-safe Kach Protocol client
 *
 * The client automatically infers all types from your deployed Move contracts.
 * All function calls are type-checked at compile time.
 *
 * @example
 * ```typescript
 * // Connect to localnet
 * const client = createKachClient();
 *
 * // Connect to testnet
 * const client = createKachClient({ network: Network.TESTNET });
 *
 * // Connect to custom fullnode
 * const client = createKachClient({
 *   fullnode: "https://fullnode.mainnet.aptoslabs.com/v1"
 * });
 *
 * // Use the client
 * const score = await client.view.trust_score.get_trust_score({
 *   functionArguments: ["0xborrower...", "0xgovernance..."],
 *   typeArguments: [],
 * });
 * ```
 */
export function createKachClient(config?: KachClientConfig) {
  // Create Aptos config
  const aptosConfig = config?.fullnode
    ? new AptosConfig({ fullnode: config.fullnode })
    : new AptosConfig({ network: config?.network ?? Network.LOCAL });

  // Create base Aptos client
  const aptos = new Aptos(aptosConfig);

  // Create Surf client with ABI - this gives us full type safety!
  // @ts-expect-error readonly error mismatch
  const surfClient = createSurfClient(aptos).useABI(KACH_ABI);

  // Add module address to the client for convenience
  const client = surfClient as typeof surfClient & {
    moduleAddress: string;
    aptos: Aptos;
  };

  client.moduleAddress = config?.moduleAddress ?? KACH_MODULE_ADDRESS;
  client.aptos = aptos;

  return client;
}

/**
 * Type helper to extract the Kach client type
 *
 * @example
 * ```typescript
 * type MyClient = KachClient;
 *
 * function doSomething(client: MyClient) {
 *   // client is fully typed!
 * }
 * ```
 */
export type KachClient = ReturnType<typeof createKachClient>;
