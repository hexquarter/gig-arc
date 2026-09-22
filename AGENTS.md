# GigEconomy

> Built with Arc Studio - money-powered apps in minutes

This is the **project memory** - what Arc Studio remembers about building this app. It helps future agents (or humans) understand and extend the project.

---

## What This App Does

A USDC-backed P2P gig economy platform. Companies post jobs, freelancers submit proposals, both parties accept onchain. USDC is escrowed (optionally milestone-by-milestone), released on deliverable approval, or refunded after deadline. Reputation counters track each party's history. Platform takes a configurable fee (default 2.5%) on each release.

## Deployed Contracts (Arc Testnet — implementations)

> All 4 are UUPS upgradeable **implementations**. In production, each must be deployed behind an ERC-1967 proxy with atomic init calldata. See `contracts/GigEconomy-design.md` §12 for the init runbook.

| Contract | Address | Explorer |
|---|---|---|
| GigTreasury | `0x4d0ccd5f5c1132f2e79b4b0c77e5e3492cf3de4d` | https://explorer.testnet.arc.io/address/0x4d0ccd5f5c1132f2e79b4b0c77e5e3492cf3de4d |
| GigReputation | `0x679ff21d00a0ac900aaa66647647a04328ee6d06` | https://explorer.testnet.arc.io/address/0x679ff21d00a0ac900aaa66647647a04328ee6d06 |
| GigEscrow | `0x1a4940b49907e6cf0691525cbcd794314d1fbb1a` | https://explorer.testnet.arc.io/address/0x1a4940b49907e6cf0691525cbcd794314d1fbb1a |
| GigRegistry | `0xc33e44b693ae368fa954107b7345c427fe480f0d` | https://explorer.testnet.arc.io/address/0xc33e44b693ae368fa954107b7345c427fe480f0d |

## Wiring order for proxy deployment
1. Deploy GigTreasury proxy → `initialize(usdcAddress, multisigAddress)`
2. Deploy GigReputation proxy → `initialize(multisigAddress)` then `setRegistry(gigRegistryProxyAddress)`
3. Deploy GigEscrow proxy → `initialize(usdcAddress, gigRegistryProxyAddress, gigTreasuryProxyAddress, 250, multisigAddress)`
4. Deploy GigRegistry proxy → `initialize(gigEscrowProxyAddress, gigReputationProxyAddress, multisigAddress)`

## Tech Stack

- Frontend: React 18, Vite, TypeScript, Tailwind CSS
- Web3: wagmi v2, viem v2, ConnectKit
- Contracts: Solidity 0.8.28 + Foundry. Sources in `contracts/`, unit tests in `contracts/test/*.t.sol`. Build with `bun run contracts:build` (`forge build`), test with `bun run contracts:test` (`forge test`).
- Wallet: injected (MetaMask, etc.)
- Chain: Arc Testnet (Chain ID: 5042002, imported from `viem/chains`)
- Token: USDC (6 decimals) (Address: 0x3600000000000000000000000000000000000000, Chain: Arc Testnet)
- Toasts: Sonner

## Key Files

- `src/App.tsx` - Main application logic
- `src/components/` - UI components
- `src/config.ts` - wagmi config (chains, connectors, transports)

## To Run

```bash
bun install
bun run dev
```
