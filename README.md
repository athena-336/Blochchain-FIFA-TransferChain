# Blochchain-FIFA-TransferChain
On-chain settlement protocol for football player transfers — automating transfer fees, solidarity contributions, sell-on clauses, and agent commissions via Solidity smart contracts. Built on Sepolia testnet.

# FIFA TransferChain

An on-chain settlement protocol that automates every financial obligation 
in a professional football transfer — built for Columbia APANPS5470, Spring 2026.

## Problem

FIFA mandates solidarity contributions and agent commission caps, but 
compliance consistently fails. In 2018, only 19.3% of solidarity contributions 
were actually paid. The FIFA Football Tribunal handled a record 21,633 cases 
in 2024/25 — largely due to disputed sell-on clauses and unpaid obligations.

## Solution

A single self-executing smart contract that settles all four payment streams 
simultaneously:

| Stream | Rule |
|---|---|
| Transfer Fee | Released in scheduled installments (2–5 tranches) |
| Solidarity | 5% per installment to training academies (FIFA RSTP Art. 21) |
| Sell-on Clause | Pre-encoded percentage to prior owners |
| Agent Commission | Hard-capped at 6% on-chain |

## How It Works

1. **Deploy** — Constructor seeds roles, fee, and deal name
2. **Activate** — FIFA admin, national association, and buyer club all sign (3-of-3 consensus)
3. **Register** — Recipients and installment schedule encoded on-chain
4. **Deposit** — Buyer club deposits full transfer fee into escrow
5. **Release** — Time-locked payouts cascade to all recipients in one transaction

## Tech Stack

- Solidity (OpenZeppelin)
- Sepolia testnet
- ethers.js + MetaMask (frontend integration)

## Demo

[Watch the end-to-end walkthrough on Sepolia](https://drive.google.com/file/d/1NIuh0iFylT_p6qzNRhqAgpDHKNCp-zhd/view)

## Market

- **TAM:** $13.1B (2025 global transfer spending)
- **SAM:** ~$10.5B (~80% involve installments or sell-on clauses)
- **SOM:** ~$131M (Year 1 target at 1% protocol adoption)

## Team

| Name | Role |
|---|---|
| Yun-Chien Huang | Market Analysis & Go-to-Market Strategy |
| Yan Lu | Smart Contract Engineering (Solidity, Sepolia deployment) |
| Yiheng Jiang | Frontend integration, Demo production |
| Maximilian Kunz | Business Strategy & Deck Design |

## Course

Columbia University · APANPS5470 Crypto, Blockchain, and Analytics · Spring 2026
