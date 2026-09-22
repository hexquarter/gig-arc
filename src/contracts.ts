/**
 * GigEconomy contract ABIs and addresses.
 * Implementation contracts deployed on Arc Testnet.
 * In production these addresses are the proxy addresses.
 */

import GigRegistryArtifact from '../contracts/out/GigRegistry.sol/GigRegistry.json'
import GigEscrowArtifact from '../contracts/out/GigEscrow.sol/GigEscrow.json'
import GigReputationArtifact from '../contracts/out/GigReputation.sol/GigReputation.json'

// Arc Testnet — implementation addresses (deployed by Arc Studio)
export const GIG_REGISTRY_ADDRESS = '0xc33e44b693ae368fa954107b7345c427fe480f0d' as const
export const GIG_ESCROW_ADDRESS = '0x1a4940b49907e6cf0691525cbcd794314d1fbb1a' as const
export const GIG_REPUTATION_ADDRESS = '0x679ff21d00a0ac900aaa66647647a04328ee6d06' as const

export const GIG_REGISTRY_ABI = GigRegistryArtifact.abi
export const GIG_ESCROW_ABI = GigEscrowArtifact.abi
export const GIG_REPUTATION_ABI = GigReputationArtifact.abi
