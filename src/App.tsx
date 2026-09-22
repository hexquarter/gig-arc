import { useState } from 'react'
import { ConnectKitButton } from 'connectkit'
import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt, useSwitchChain } from 'wagmi'
import { erc20Abi } from 'viem'
import { arcTestnet } from 'viem/chains'
import { motion, AnimatePresence } from 'framer-motion'
import {
  Briefcase, Plus, User, Star, ChevronRight,
  ExternalLink, Loader2, CheckCircle, Clock, XCircle,
  DollarSign, FileText, Shield, ArrowLeft, Hash
} from 'lucide-react'
import { getUsdc, buildTxExplorerUrl } from '@/onchain-facts'
import { Amount, parseAmount, usdcDecimalsFor } from '@/onchain-money'
import {
  GIG_REGISTRY_ADDRESS, GIG_ESCROW_ADDRESS, GIG_REPUTATION_ADDRESS,
  GIG_REGISTRY_ABI, GIG_REPUTATION_ABI
} from './contracts'

const CHAIN_ID = arcTestnet.id
const USDC = getUsdc(CHAIN_ID)!

// ─── glass helpers ────────────────────────────────────────────────────────────
const glass = {
  card: {
    background: 'rgba(255,255,255,0.72)',
    backdropFilter: 'blur(24px) saturate(180%)',
    WebkitBackdropFilter: 'blur(24px) saturate(180%)',
    border: '1px solid rgba(18,45,69,0.10)',
    borderRadius: '20px',
  } as React.CSSProperties,
  inner: {
    background: 'rgba(255,255,255,0.55)',
    backdropFilter: 'blur(12px)',
    WebkitBackdropFilter: 'blur(12px)',
    border: '1px solid rgba(18,45,69,0.08)',
    borderRadius: '14px',
  } as React.CSSProperties,
  nav: {
    background: 'rgba(255,255,255,0.85)',
    backdropFilter: 'blur(20px) saturate(180%)',
    WebkitBackdropFilter: 'blur(20px) saturate(180%)',
    borderBottom: '1px solid rgba(18,45,69,0.08)',
  } as React.CSSProperties,
}

// ─── status helpers ────────────────────────────────────────────────────────────
const JOB_STATUS = ['Open', 'Locked', 'Completed', 'Cancelled'] as const
const MILESTONE_STATUS = ['Pending', 'Submitted', 'Approved', 'Refunded'] as const

function statusColor(s: string) {
  if (s === 'Open') return '#1061a6'
  if (s === 'Locked') return '#a06010'
  if (s === 'Completed') return '#1a8047'
  if (s === 'Cancelled') return '#ba2b4c'
  return '#6b6580'
}

function formatAddr(a: string) {
  return `${a.slice(0, 6)}…${a.slice(-4)}`
}

function formatUsdc(raw: bigint) {
  return Amount.fromRaw(raw, usdcDecimalsFor(CHAIN_ID)).toFixed(2)
}

// ─── CTA button ───────────────────────────────────────────────────────────────
function CtaButton({
  label, onClick, disabled, loading, full = true,
}: {
  label: string; onClick?: () => void; disabled?: boolean; loading?: boolean; full?: boolean
}) {
  return (
    <button
      disabled={disabled || loading}
      onClick={onClick}
      className={`${full ? 'w-full' : ''} rounded-2xl py-3.5 px-6 text-sm font-semibold text-white transition-all hover:scale-[1.01] active:scale-[0.99] disabled:cursor-not-allowed disabled:opacity-40 flex items-center justify-center gap-2`}
      style={{ background: 'var(--accent)' }}
    >
      {loading && <Loader2 className="size-4 animate-spin" />}
      {label}
    </button>
  )
}

// ─── ghost button ─────────────────────────────────────────────────────────────
function GhostButton({ label, onClick, small }: { label: string; onClick?: () => void; small?: boolean }) {
  return (
    <button
      onClick={onClick}
      className={`rounded-xl border font-semibold transition-all hover:bg-black/5 active:scale-[0.98] ${small ? 'px-3 py-1.5 text-xs' : 'px-4 py-2 text-sm'}`}
      style={{ borderColor: 'var(--border-strong)', color: 'var(--ink-2)' }}
    >
      {label}
    </button>
  )
}

// ─── chain guard ──────────────────────────────────────────────────────────────
function useChainGuard() {
  const { chainId } = useAccount()
  const { switchChain, isPending } = useSwitchChain()
  const wrongChain = chainId !== CHAIN_ID
  const ensureChain = () => { if (wrongChain) switchChain({ chainId: CHAIN_ID }) }
  return { wrongChain, ensureChain, switching: isPending }
}

// ─── USDC balance ─────────────────────────────────────────────────────────────
function useUsdcBalance(address?: string) {
  const { data } = useReadContract({
    address: USDC.address as `0x${string}`,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: [address as `0x${string}`],
    chainId: CHAIN_ID,
    query: { enabled: !!address },
  })
  return data
}

// ─── JobCard ──────────────────────────────────────────────────────────────────
function JobCard({ jobId, onOpen }: { jobId: bigint; onOpen: (id: bigint) => void }) {
  const { data: info } = useReadContract({
    address: GIG_REGISTRY_ADDRESS,
    abi: GIG_REGISTRY_ABI,
    functionName: 'getJobInfo',
    args: [jobId],
    chainId: CHAIN_ID,
  })

  if (!info) return (
    <div className="rounded-xl p-4 animate-pulse" style={{ background: 'var(--surface-muted)', height: '88px' }} />
  )

  const [id, client, , totalBudget, deadline, status, , , milestoneCount] = info as [bigint, string, string, bigint, bigint, number, bigint, boolean, bigint]
  const statusLabel = JOB_STATUS[Number(status)] ?? 'Unknown'
  const deadlineDate = new Date(Number(deadline) * 1000)
  const nowMs = new Date().getTime()
  const expired = nowMs > Number(deadline) * 1000

  return (
    <motion.button
      initial={{ opacity: 0, y: 8 }}
      animate={{ opacity: 1, y: 0 }}
      whileHover={{ scale: 1.01 }}
      whileTap={{ scale: 0.99 }}
      onClick={() => onOpen(id)}
      className="w-full text-left rounded-2xl p-4 flex items-center gap-4"
      style={glass.card}
    >
      <div className="flex size-10 shrink-0 items-center justify-center rounded-xl" style={{ background: 'var(--surface-muted)' }}>
        <Briefcase className="size-5" style={{ color: 'var(--ink-2)' }} />
      </div>
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          <span className="mono text-xs" style={{ color: 'var(--subtle)' }}>#{id.toString()}</span>
          <span className="rounded-full px-2 py-0.5 text-xs font-semibold"
            style={{ background: `${statusColor(statusLabel)}18`, color: statusColor(statusLabel) }}>
            {statusLabel}
          </span>
          {Number(milestoneCount) > 1 && (
            <span className="rounded-full px-2 py-0.5 text-xs font-semibold"
              style={{ background: 'rgba(16,97,166,0.08)', color: '#1061a6' }}>
              {milestoneCount.toString()} milestones
            </span>
          )}
        </div>
        <div className="mt-0.5 flex items-center gap-2">
          <span className="display font-semibold tabular-nums" style={{ color: 'var(--ink)' }}>
            {formatUsdc(totalBudget)} <span className="text-xs font-normal" style={{ color: 'var(--subtle)' }}>USDC</span>
          </span>
        </div>
        <div className="mt-0.5 flex items-center gap-1.5 text-xs" style={{ color: expired ? 'var(--danger)' : 'var(--subtle)' }}>
          <Clock className="size-3" />
          {expired ? 'Expired' : deadlineDate.toLocaleDateString()}
          <span style={{ color: 'var(--border-strong)' }}>·</span>
          <span>by {formatAddr(client)}</span>
        </div>
      </div>
      <ChevronRight className="size-4 shrink-0" style={{ color: 'var(--subtle)' }} />
    </motion.button>
  )
}

// ─── JobBoard view ────────────────────────────────────────────────────────────
function JobBoard({ onOpenJob }: { onOpenJob: (id: bigint) => void }) {
  const { data: jobCount } = useReadContract({
    address: GIG_REGISTRY_ADDRESS,
    abi: GIG_REGISTRY_ABI,
    functionName: 'jobCount',
    chainId: CHAIN_ID,
  })

  const count = jobCount as bigint | undefined
  const ids = count ? Array.from({ length: Number(count) }, (_, i) => BigInt(i + 1)).reverse() : []

  return (
    <div className="flex flex-col gap-3">
      {!count && (
        <div className="flex flex-col items-center gap-3 py-16" style={{ color: 'var(--subtle)' }}>
          <Briefcase className="size-10 opacity-30" />
          <p className="text-sm">No jobs posted yet. Be the first!</p>
        </div>
      )}
      {ids.map(id => <JobCard key={id.toString()} jobId={id} onOpen={onOpenJob} />)}
    </div>
  )
}

// ─── PostJob view ─────────────────────────────────────────────────────────────
function PostJob({ onBack }: { onBack: () => void }) {
  const { address, isConnected } = useAccount()
  const { wrongChain, ensureChain } = useChainGuard()
  const balance = useUsdcBalance(address)

  const [budget, setBudget] = useState('')
  const [descHash, setDescHash] = useState('')
  const [daysFromNow, setDaysFromNow] = useState('14')
  const [useMilestones, setUseMilestones] = useState(false)
  const [milestones, setMilestones] = useState([{ amount: '', days: '7' }])

  const { writeContract, data: hash, isPending, error } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  const addMilestone = () => setMilestones(m => [...m, { amount: '', days: '7' }])
  const removeMilestone = (i: number) => setMilestones(m => m.filter((_, idx) => idx !== i))

  const handleApprove = () => {
    if (wrongChain) { ensureChain(); return }
    if (!budget || !descHash) return
    const parsed = parseAmount(CHAIN_ID, budget)
    writeContract({
      address: USDC.address as `0x${string}`,
      abi: erc20Abi,
      functionName: 'approve',
      args: [GIG_ESCROW_ADDRESS, parsed.raw],
    })
  }

  const handlePost = () => {
    if (wrongChain) { ensureChain(); return }
    if (!budget || !descHash) return
    const now = Math.floor(Date.now() / 1000)
    const budgetRaw = parseAmount(CHAIN_ID, budget).raw
    const descBytes = `0x${Buffer.from(descHash).toString('hex').padEnd(64, '0').slice(0, 64)}`
    const deadline = BigInt(now + Number(daysFromNow) * 86400)

    if (!useMilestones || milestones.length === 0) {
      writeContract({
        address: GIG_REGISTRY_ADDRESS,
        abi: GIG_REGISTRY_ABI,
        functionName: 'postJob',
        args: [descBytes, budgetRaw, deadline, []],
      })
    } else {
      const inputs = milestones.map((m, i) => ({
        amount: parseAmount(CHAIN_ID, m.amount || '0').raw,
        deadline: BigInt(now + milestones.slice(0, i + 1).reduce((acc, ms) => acc + Number(ms.days), 0) * 86400),
      }))
      writeContract({
        address: GIG_REGISTRY_ADDRESS,
        abi: GIG_REGISTRY_ABI,
        functionName: 'postJob',
        args: [descBytes, budgetRaw, deadline, inputs],
      })
    }
  }

  return (
    <div className="flex flex-col gap-4">
      <button onClick={onBack} className="flex items-center gap-1.5 text-sm font-medium" style={{ color: 'var(--muted)' }}>
        <ArrowLeft className="size-4" /> Back to board
      </button>

      <div className="rounded-2xl p-5 flex flex-col gap-4" style={glass.card}>
        <h2 className="display text-lg font-semibold" style={{ color: 'var(--ink)' }}>Post a New Job</h2>

        {/* Budget */}
        <div>
          <label className="mb-1 block text-xs font-semibold" style={{ color: 'var(--muted)' }}>TOTAL BUDGET (USDC)</label>
          <div className="flex items-center gap-3 rounded-xl p-3" style={glass.inner}>
            <DollarSign className="size-4 shrink-0" style={{ color: 'var(--subtle)' }} />
            <input
              inputMode="decimal"
              value={budget}
              onChange={e => { const v = e.target.value.replace(/[^0-9.]/g, ''); setBudget(v) }}
              placeholder="500.00"
              className="display w-full bg-transparent text-2xl font-bold tabular-nums outline-none placeholder:opacity-30"
              style={{ color: 'var(--ink)' }}
            />
            <span className="text-sm font-medium shrink-0" style={{ color: 'var(--subtle)' }}>USDC</span>
          </div>
          {balance !== undefined && (
            <p className="mt-1 text-xs" style={{ color: 'var(--subtle)' }}>
              Wallet balance: {formatUsdc(balance)} USDC
            </p>
          )}
        </div>

        {/* Description hash */}
        <div>
          <label className="mb-1 block text-xs font-semibold" style={{ color: 'var(--muted)' }}>JOB TITLE / DESCRIPTION</label>
          <div className="flex items-center gap-2 rounded-xl p-3" style={glass.inner}>
            <FileText className="size-4 shrink-0" style={{ color: 'var(--subtle)' }} />
            <input
              value={descHash}
              onChange={e => setDescHash(e.target.value)}
              placeholder="e.g. Build a landing page for our product"
              className="w-full bg-transparent text-sm outline-none"
              style={{ color: 'var(--ink)' }}
            />
          </div>
          <p className="mt-1 text-xs" style={{ color: 'var(--subtle)' }}>Stored onchain as a hash. Keep a copy off-chain.</p>
        </div>

        {/* Deadline */}
        <div>
          <label className="mb-1 block text-xs font-semibold" style={{ color: 'var(--muted)' }}>DEADLINE</label>
          <div className="flex items-center gap-2 rounded-xl p-3" style={glass.inner}>
            <Clock className="size-4 shrink-0" style={{ color: 'var(--subtle)' }} />
            <input
              type="number"
              min="1"
              value={daysFromNow}
              onChange={e => setDaysFromNow(e.target.value)}
              className="w-full bg-transparent text-sm outline-none"
              style={{ color: 'var(--ink)' }}
            />
            <span className="shrink-0 text-sm" style={{ color: 'var(--subtle)' }}>days from now</span>
          </div>
        </div>

        {/* Milestones toggle */}
        <div className="flex items-center justify-between rounded-xl p-3" style={glass.inner}>
          <span className="text-sm font-medium" style={{ color: 'var(--ink-2)' }}>Use milestones</span>
          <button
            onClick={() => setUseMilestones(v => !v)}
            className="relative h-6 w-11 rounded-full transition-all"
            style={{ background: useMilestones ? 'var(--accent)' : 'var(--border-strong)' }}
          >
            <span className={`absolute top-0.5 size-5 rounded-full bg-white shadow transition-all ${useMilestones ? 'left-5' : 'left-0.5'}`} />
          </button>
        </div>

        {/* Milestone editor */}
        <AnimatePresence>
          {useMilestones && (
            <motion.div initial={{ opacity: 0, height: 0 }} animate={{ opacity: 1, height: 'auto' }} exit={{ opacity: 0, height: 0 }} className="flex flex-col gap-2">
              {milestones.map((m, i) => (
                <div key={i} className="flex items-center gap-2 rounded-xl p-3" style={glass.inner}>
                  <span className="mono text-xs shrink-0" style={{ color: 'var(--subtle)' }}>M{i + 1}</span>
                  <input
                    inputMode="decimal"
                    value={m.amount}
                    onChange={e => setMilestones(ms => ms.map((x, xi) => xi === i ? { ...x, amount: e.target.value.replace(/[^0-9.]/g, '') } : x))}
                    placeholder="Amount"
                    className="min-w-0 flex-1 bg-transparent text-sm tabular-nums outline-none"
                    style={{ color: 'var(--ink)' }}
                  />
                  <span className="text-xs shrink-0" style={{ color: 'var(--subtle)' }}>USDC</span>
                  <input
                    type="number"
                    min="1"
                    value={m.days}
                    onChange={e => setMilestones(ms => ms.map((x, xi) => xi === i ? { ...x, days: e.target.value } : x))}
                    className="w-14 bg-transparent text-sm outline-none text-right"
                    style={{ color: 'var(--ink)' }}
                  />
                  <span className="text-xs shrink-0" style={{ color: 'var(--subtle)' }}>d</span>
                  {milestones.length > 1 && (
                    <button onClick={() => removeMilestone(i)} className="ml-1 rounded-lg p-1 hover:bg-red-50">
                      <XCircle className="size-3.5" style={{ color: 'var(--danger)' }} />
                    </button>
                  )}
                </div>
              ))}
              {milestones.length < 20 && (
                <button onClick={addMilestone} className="flex items-center gap-1.5 rounded-xl px-3 py-2 text-xs font-semibold" style={{ color: 'var(--accent-hover)', background: 'rgba(16,97,166,0.06)' }}>
                  <Plus className="size-3" /> Add milestone
                </button>
              )}
            </motion.div>
          )}
        </AnimatePresence>

        {/* Actions */}
        {!isConnected ? (
          <ConnectKitButton />
        ) : isSuccess ? (
          <div className="flex items-center gap-2 rounded-xl p-3" style={{ background: 'rgba(26,128,71,0.08)' }}>
            <CheckCircle className="size-4" style={{ color: 'var(--success)' }} />
            <span className="text-sm font-medium" style={{ color: 'var(--success)' }}>Job posted!</span>
            {hash && (
              <a href={buildTxExplorerUrl(CHAIN_ID, hash)} target="_blank" rel="noreferrer"
                className="ml-auto flex items-center gap-1 text-xs" style={{ color: 'var(--accent-hover)' }}>
                View <ExternalLink className="size-3" />
              </a>
            )}
          </div>
        ) : error ? (
          <div className="rounded-xl p-3 text-xs" style={{ background: 'rgba(186,43,76,0.08)', color: 'var(--danger)' }}>
            {(error as Error).message?.includes('user rejected') ? 'Transaction cancelled.' : 'Transaction failed. Check inputs and try again.'}
          </div>
        ) : (
          <div className="flex flex-col gap-2">
            <p className="text-xs" style={{ color: 'var(--subtle)' }}>First allow the platform to hold your USDC in escrow, then post the job.</p>
            <GhostButton label="Step 1: Allow USDC" onClick={handleApprove} />
            <CtaButton
              label={wrongChain ? 'Switch to Arc Testnet' : isPending ? 'Confirm in wallet…' : isConfirming ? 'Confirming…' : 'Step 2: Post Job'}
              onClick={handlePost}
              loading={isPending || isConfirming}
              disabled={!budget || !descHash}
            />
          </div>
        )}
      </div>
    </div>
  )
}

// ─── ProposalRow ──────────────────────────────────────────────────────────────
function ProposalRow({ jobId, proposalId, jobClient }: { jobId: bigint; proposalId: bigint; jobClient: string }) {
  const { address } = useAccount()
  const { wrongChain, ensureChain } = useChainGuard()
  const { data } = useReadContract({
    address: GIG_REGISTRY_ADDRESS,
    abi: GIG_REGISTRY_ABI,
    functionName: 'getProposal',
    args: [jobId, proposalId],
    chainId: CHAIN_ID,
  })
  const { writeContract, data: hash, isPending } = useWriteContract()
  const { isSuccess } = useWaitForTransactionReceipt({ hash })

  if (!data) return null
  const proposal = data as { id: bigint; freelancer: string; quote: bigint; timelineHash: string; clientAccepted: boolean; freelancerAccepted: boolean }

  const isClient = address?.toLowerCase() === jobClient.toLowerCase()
  const isFreelancer = address?.toLowerCase() === proposal.freelancer.toLowerCase()
  const canAccept = (isClient && !proposal.clientAccepted) || (isFreelancer && !proposal.freelancerAccepted)

  const handleAccept = () => {
    if (wrongChain) { ensureChain(); return }
    writeContract({
      address: GIG_REGISTRY_ADDRESS,
      abi: GIG_REGISTRY_ABI,
      functionName: 'acceptProposal',
      args: [jobId, proposalId],
    })
  }

  return (
    <div className="flex items-center gap-3 rounded-xl p-3" style={glass.inner}>
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          <span className="text-sm font-semibold tabular-nums" style={{ color: 'var(--ink)' }}>
            {formatUsdc(proposal.quote)} USDC
          </span>
          <span className="mono text-xs" style={{ color: 'var(--subtle)' }}>{formatAddr(proposal.freelancer)}</span>
        </div>
        <div className="mt-0.5 flex items-center gap-2 text-xs" style={{ color: 'var(--subtle)' }}>
          {proposal.clientAccepted && <span style={{ color: 'var(--success)' }}>Client: ✓</span>}
          {!proposal.clientAccepted && isClient && <span style={{ color: 'var(--muted)' }}>Client: pending</span>}
          {proposal.freelancerAccepted && <span style={{ color: 'var(--success)' }}>Freelancer: ✓</span>}
          {!proposal.freelancerAccepted && isFreelancer && <span style={{ color: 'var(--muted)' }}>You: pending</span>}
        </div>
      </div>
      {!isSuccess && canAccept && (
        <GhostButton label={isPending ? '…' : 'Accept'} onClick={handleAccept} small />
      )}
      {isSuccess && <CheckCircle className="size-4" style={{ color: 'var(--success)' }} />}
    </div>
  )
}

// ─── MilestoneRow ─────────────────────────────────────────────────────────────
function MilestoneRow({
  jobId, idx, jobClient, freelancer, hasMilestones
}: {
  jobId: bigint; idx: number; jobClient: string; freelancer: string; hasMilestones: boolean
}) {
  const { address } = useAccount()
  const { wrongChain, ensureChain } = useChainGuard()
  const { data } = useReadContract({
    address: GIG_REGISTRY_ADDRESS,
    abi: GIG_REGISTRY_ABI,
    functionName: 'getJobMilestone',
    args: [jobId, BigInt(idx)],
    chainId: CHAIN_ID,
  })
  const { writeContract, data: hash, isPending } = useWriteContract()
  const { isSuccess } = useWaitForTransactionReceipt({ hash })

  const [deliverableInput, setDeliverableInput] = useState('')
  const [showInput, setShowInput] = useState(false)

  if (!data) return null
  const [amount, deadline, deliverableHash, status] = data as [bigint, bigint, string, number]
  const statusLabel = MILESTONE_STATUS[status] ?? 'Unknown'
  const isClient = address?.toLowerCase() === jobClient.toLowerCase()
  const isFreelancer = address?.toLowerCase() === freelancer.toLowerCase()
  const deadlineDate = new Date(Number(deadline) * 1000)

  const handleSubmit = () => {
    if (wrongChain) { ensureChain(); return }
    const contentBytes = `0x${Buffer.from(deliverableInput).toString('hex').padEnd(64, '0').slice(0, 64)}`
    writeContract({
      address: GIG_REGISTRY_ADDRESS,
      abi: GIG_REGISTRY_ABI,
      functionName: 'submitDeliverable',
      args: [jobId, BigInt(idx), contentBytes],
    })
  }

  const handleApprove = () => {
    if (wrongChain) { ensureChain(); return }
    writeContract({
      address: GIG_REGISTRY_ADDRESS,
      abi: GIG_REGISTRY_ABI,
      functionName: 'approveDeliverable',
      args: [jobId, BigInt(idx)],
    })
  }

  return (
    <div className="flex flex-col gap-2 rounded-xl p-3" style={glass.inner}>
      <div className="flex items-center gap-2">
        {hasMilestones && <span className="mono text-xs shrink-0" style={{ color: 'var(--subtle)' }}>M{idx + 1}</span>}
        <span className="flex-1 text-sm font-semibold tabular-nums" style={{ color: 'var(--ink)' }}>
          {formatUsdc(amount)} USDC
        </span>
        <span className="rounded-full px-2 py-0.5 text-xs font-semibold"
          style={{ background: `${statusColor(statusLabel)}18`, color: statusColor(statusLabel) }}>
          {statusLabel}
        </span>
      </div>
      <div className="flex items-center gap-1 text-xs" style={{ color: 'var(--subtle)' }}>
        <Clock className="size-3" /> Due {deadlineDate.toLocaleDateString()}
        {deliverableHash !== '0x' + '0'.repeat(64) && (
          <>
            <span style={{ color: 'var(--border-strong)' }}>·</span>
            <Hash className="size-3" />
            <span className="mono">{deliverableHash.slice(0, 10)}…</span>
          </>
        )}
      </div>
      {/* Submit deliverable */}
      {!isSuccess && isFreelancer && statusLabel === 'Pending' && (
        showInput ? (
          <div className="flex gap-2">
            <input
              value={deliverableInput}
              onChange={e => setDeliverableInput(e.target.value)}
              placeholder="Deliverable link or description"
              className="flex-1 min-w-0 rounded-xl px-3 py-2 text-xs outline-none"
              style={{ background: 'var(--surface-muted)', color: 'var(--ink)' }}
            />
            <button
              onClick={handleSubmit}
              disabled={!deliverableInput || isPending}
              className="rounded-xl px-3 py-2 text-xs font-semibold text-white disabled:opacity-40"
              style={{ background: 'var(--accent)' }}
            >
              {isPending ? <Loader2 className="size-3 animate-spin" /> : 'Submit'}
            </button>
          </div>
        ) : (
          <GhostButton label="Submit Deliverable" onClick={() => setShowInput(true)} small />
        )
      )}
      {/* Approve */}
      {!isSuccess && isClient && statusLabel === 'Submitted' && (
        <GhostButton label={isPending ? 'Approving…' : 'Approve & Release USDC'} onClick={handleApprove} small />
      )}
      {isSuccess && <span className="text-xs" style={{ color: 'var(--success)' }}>Done!</span>}
    </div>
  )
}

// ─── JobDetail view ───────────────────────────────────────────────────────────
function JobDetail({ jobId, onBack }: { jobId: bigint; onBack: () => void }) {
  const { address, isConnected } = useAccount()
  const { wrongChain, ensureChain } = useChainGuard()

  const { data: info } = useReadContract({
    address: GIG_REGISTRY_ADDRESS,
    abi: GIG_REGISTRY_ABI,
    functionName: 'getJobInfo',
    args: [jobId],
    chainId: CHAIN_ID,
  })
  const { data: freelancer } = useReadContract({
    address: GIG_REGISTRY_ADDRESS,
    abi: GIG_REGISTRY_ABI,
    functionName: 'getAcceptedFreelancer',
    args: [jobId],
    chainId: CHAIN_ID,
  })

  const [quote, setQuote] = useState('')
  const { writeContract, data: hash, isPending } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  if (!info) return (
    <div className="flex flex-col gap-4 animate-pulse">
      <div className="h-8 rounded-xl" style={{ background: 'var(--surface-muted)' }} />
      <div className="h-48 rounded-2xl" style={{ background: 'var(--surface-muted)' }} />
    </div>
  )

  const [id, client, , totalBudget, deadline, status, , hasMilestones, milestoneCount] = info as [bigint, string, string, bigint, bigint, number, bigint, boolean, bigint]
  const statusLabel = JOB_STATUS[Number(status)] ?? 'Unknown'
  const isClient = address?.toLowerCase() === client.toLowerCase()
  const isLocked = statusLabel === 'Locked'
  const isOpen = statusLabel === 'Open'
  const freelancerAddr = (freelancer as string | undefined) ?? ''

  const handleSubmitProposal = () => {
    if (wrongChain) { ensureChain(); return }
    const quoteRaw = parseAmount(CHAIN_ID, quote).raw
    const timelineBytes = '0x' + '0'.repeat(64) as `0x${string}`
    writeContract({
      address: GIG_REGISTRY_ADDRESS,
      abi: GIG_REGISTRY_ABI,
      functionName: 'submitProposal',
      args: [jobId, quoteRaw, timelineBytes],
    })
  }

  const handleReclaim = () => {
    if (wrongChain) { ensureChain(); return }
    writeContract({
      address: GIG_REGISTRY_ADDRESS,
      abi: GIG_REGISTRY_ABI,
      functionName: 'reclaimEscrow',
      args: [jobId],
    })
  }

  const milestoneIdxs = Array.from({ length: Number(milestoneCount) }, (_, i) => i)

  return (
    <div className="flex flex-col gap-4">
      <button onClick={onBack} className="flex items-center gap-1.5 text-sm font-medium" style={{ color: 'var(--muted)' }}>
        <ArrowLeft className="size-4" /> Back to board
      </button>

      {/* Header */}
      <div className="rounded-2xl p-5 flex flex-col gap-3" style={glass.card}>
        <div className="flex items-center gap-2">
          <span className="mono text-xs" style={{ color: 'var(--subtle)' }}>Job #{id.toString()}</span>
          <span className="rounded-full px-2 py-0.5 text-xs font-semibold"
            style={{ background: `${statusColor(statusLabel)}18`, color: statusColor(statusLabel) }}>
            {statusLabel}
          </span>
          {hasMilestones && (
            <span className="rounded-full px-2 py-0.5 text-xs font-semibold"
              style={{ background: 'rgba(16,97,166,0.08)', color: '#1061a6' }}>
              {milestoneCount.toString()} milestones
            </span>
          )}
        </div>
        <div className="flex items-baseline gap-1.5">
          <span className="display text-3xl font-bold tabular-nums" style={{ color: 'var(--ink)' }}>
            {formatUsdc(totalBudget)}
          </span>
          <span className="text-sm font-medium" style={{ color: 'var(--subtle)' }}>USDC</span>
        </div>
        <div className="grid grid-cols-2 gap-2 text-xs" style={{ color: 'var(--subtle)' }}>
          <div className="flex flex-col gap-0.5">
            <span style={{ color: 'var(--muted)' }}>CLIENT</span>
            <span className="mono" style={{ color: 'var(--ink-2)' }}>{formatAddr(client)}</span>
          </div>
          {freelancerAddr && freelancerAddr !== '0x0000000000000000000000000000000000000000' && (
            <div className="flex flex-col gap-0.5">
              <span style={{ color: 'var(--muted)' }}>FREELANCER</span>
              <span className="mono" style={{ color: 'var(--ink-2)' }}>{formatAddr(freelancerAddr)}</span>
            </div>
          )}
          <div className="flex flex-col gap-0.5">
            <span style={{ color: 'var(--muted)' }}>DEADLINE</span>
            <span style={{ color: 'var(--ink-2)' }}>{new Date(Number(deadline) * 1000).toLocaleDateString()}</span>
          </div>
        </div>
      </div>

      {/* Milestones / deliverables */}
      {(isLocked || statusLabel === 'Completed') && (
        <div className="flex flex-col gap-2">
          <h3 className="text-xs font-semibold" style={{ color: 'var(--muted)' }}>
            {hasMilestones ? 'MILESTONES' : 'DELIVERABLE'}
          </h3>
          {milestoneIdxs.map(i => (
            <MilestoneRow
              key={i}
              jobId={jobId}
              idx={i}
              jobClient={client}
              freelancer={freelancerAddr}
              hasMilestones={hasMilestones}
            />
          ))}
        </div>
      )}

      {/* Proposals */}
      {isOpen && (
        <div className="flex flex-col gap-2">
          <h3 className="text-xs font-semibold" style={{ color: 'var(--muted)' }}>PROPOSALS</h3>
          {[1, 2, 3, 4, 5].map(i => (
            <ProposalRow key={i} jobId={jobId} proposalId={BigInt(i)} jobClient={client} />
          ))}

          {/* Submit proposal */}
          {!isClient && isConnected && !isSuccess && (
            <div className="rounded-2xl p-4 flex flex-col gap-3 mt-1" style={glass.card}>
              <h4 className="text-sm font-semibold" style={{ color: 'var(--ink)' }}>Submit Your Proposal</h4>
              <div className="flex items-center gap-2 rounded-xl p-3" style={glass.inner}>
                <DollarSign className="size-4 shrink-0" style={{ color: 'var(--subtle)' }} />
                <input
                  inputMode="decimal"
                  value={quote}
                  onChange={e => setQuote(e.target.value.replace(/[^0-9.]/g, ''))}
                  placeholder="Your quote"
                  className="display w-full bg-transparent text-2xl font-bold tabular-nums outline-none placeholder:opacity-30"
                  style={{ color: 'var(--ink)' }}
                />
                <span className="shrink-0 text-sm" style={{ color: 'var(--subtle)' }}>USDC</span>
              </div>
              <CtaButton
                label={wrongChain ? 'Switch to Arc Testnet' : isPending ? 'Confirm in wallet…' : isConfirming ? 'Confirming…' : 'Submit Proposal'}
                onClick={handleSubmitProposal}
                loading={isPending}
                disabled={!quote}
              />
            </div>
          )}
          {isSuccess && (
            <div className="flex items-center gap-2 rounded-xl p-3" style={{ background: 'rgba(26,128,71,0.08)' }}>
              <CheckCircle className="size-4" style={{ color: 'var(--success)' }} />
              <span className="text-sm font-medium" style={{ color: 'var(--success)' }}>Proposal submitted!</span>
              {hash && (
                <a href={buildTxExplorerUrl(CHAIN_ID, hash)} target="_blank" rel="noreferrer"
                  className="ml-auto flex items-center gap-1 text-xs" style={{ color: 'var(--accent-hover)' }}>
                  View <ExternalLink className="size-3" />
                </a>
              )}
            </div>
          )}
        </div>
      )}

      {/* Client reclaim */}
      {isClient && isLocked && (
        <GhostButton label="Reclaim Escrow (after deadline + grace)" onClick={handleReclaim} />
      )}
    </div>
  )
}

// ─── Reputation view ──────────────────────────────────────────────────────────
function ReputationView() {
  const { address, isConnected } = useAccount()
  const [lookup, setLookup] = useState(address ?? '')

  const { data: record } = useReadContract({
    address: GIG_REPUTATION_ADDRESS,
    abi: GIG_REPUTATION_ABI,
    functionName: 'getRecord',
    args: [lookup as `0x${string}`],
    chainId: CHAIN_ID,
    query: { enabled: !!lookup && lookup.startsWith('0x') && lookup.length === 42 },
  })

  const r = record as { jobsCompleted: bigint; jobsCancelled: bigint; totalUsdcEarned: bigint; totalUsdcSpent: bigint; score: bigint } | undefined

  return (
    <div className="flex flex-col gap-4">
      {/* Search */}
      <div className="flex gap-2 rounded-2xl p-4" style={glass.card}>
        <input
          value={lookup}
          onChange={e => setLookup(e.target.value)}
          placeholder="0x… wallet address"
          className="mono flex-1 min-w-0 bg-transparent text-sm outline-none"
          style={{ color: 'var(--ink)' }}
        />
        {isConnected && address && (
          <GhostButton label="Mine" onClick={() => setLookup(address)} small />
        )}
      </div>

      {r && (
        <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} className="rounded-2xl p-5 flex flex-col gap-4" style={glass.card}>
          <div className="flex items-center gap-3">
            <div className="flex size-12 items-center justify-center rounded-2xl" style={{ background: 'var(--surface-muted)' }}>
              <User className="size-6" style={{ color: 'var(--ink-2)' }} />
            </div>
            <div>
              <div className="mono text-sm" style={{ color: 'var(--ink-2)' }}>{formatAddr(lookup)}</div>
              <div className="flex items-center gap-1">
                <Star className="size-3.5" style={{ color: '#f59e0b' }} />
                <span className="display text-xl font-bold tabular-nums" style={{ color: 'var(--ink)' }}>
                  {r.score.toString()}
                </span>
                <span className="text-xs" style={{ color: 'var(--subtle)' }}>reputation score</span>
              </div>
            </div>
          </div>

          <div className="grid grid-cols-2 gap-3">
            {([
              { label: 'Jobs Completed', value: r.jobsCompleted.toString(), color: 'var(--success)' },
              { label: 'Jobs Cancelled', value: r.jobsCancelled.toString(), color: 'var(--danger)' },
              { label: 'USDC Earned', value: `${formatUsdc(r.totalUsdcEarned)} USDC`, color: 'var(--ink)' },
              { label: 'USDC Spent', value: `${formatUsdc(r.totalUsdcSpent)} USDC`, color: 'var(--ink)' },
            ] as const).map(({ label, value, color }) => (
              <div key={label} className="flex flex-col gap-0.5 rounded-xl p-3" style={glass.inner}>
                <span className="text-xs" style={{ color: 'var(--muted)' }}>{label.toUpperCase()}</span>
                <span className="display text-lg font-semibold tabular-nums" style={{ color }}>{value}</span>
              </div>
            ))}
          </div>

          <p className="text-xs" style={{ color: 'var(--subtle)' }}>
            Score = (completed × 100) + (earned ÷ 1 USDC) − (cancelled × 50). Updated on every job completion or cancellation.
          </p>
        </motion.div>
      )}

      {!r && lookup.startsWith('0x') && lookup.length === 42 && (
        <div className="flex flex-col items-center gap-2 py-12" style={{ color: 'var(--subtle)' }}>
          <Shield className="size-10 opacity-30" />
          <p className="text-sm">No reputation record yet for this address.</p>
        </div>
      )}
    </div>
  )
}

// ─── Nav tabs ─────────────────────────────────────────────────────────────────
type Tab = 'board' | 'post' | 'reputation'

function NavTab({ active, label, icon: Icon, onClick }: {
  active: boolean; label: string; icon: React.FC<{ className?: string; style?: React.CSSProperties }>; onClick: () => void
}) {
  return (
    <button
      onClick={onClick}
      className="flex flex-1 flex-col items-center gap-1 py-2.5 transition-all"
      style={{ color: active ? 'var(--accent)' : 'var(--subtle)' }}
    >
      <Icon className="size-5" />
      <span className="text-xs font-semibold" style={{ letterSpacing: '0.04em' }}>{label}</span>
      {active && <span className="h-0.5 w-5 rounded-full" style={{ background: 'var(--accent)' }} />}
    </button>
  )
}

// ─── Root App ─────────────────────────────────────────────────────────────────
export default function App() {
  const [tab, setTab] = useState<Tab>('board')
  const [selectedJobId, setSelectedJobId] = useState<bigint | null>(null)

  const handleOpenJob = (id: bigint) => { setSelectedJobId(id) }
  const handleBack = () => { setSelectedJobId(null) }
  const handleTabChange = (t: Tab) => { setSelectedJobId(null); setTab(t) }

  return (
    <div className="min-h-dvh flex flex-col" style={{ background: 'var(--bg-gradient)' }}>
      {/* Top nav */}
      <header className="sticky top-0 z-40 px-4 py-3 flex items-center justify-between" style={glass.nav}>
        <div className="flex items-center gap-2">
          <div className="flex size-8 items-center justify-center rounded-xl" style={{ background: 'var(--accent)' }}>
            <Briefcase className="size-4 text-white" />
          </div>
          <span className="display font-bold text-base" style={{ color: 'var(--ink)' }}>GigEconomy</span>
          <span className="rounded-full px-2 py-0.5 text-xs font-semibold" style={{ background: 'rgba(16,97,166,0.08)', color: '#1061a6' }}>Arc Testnet</span>
        </div>
        <ConnectKitButton />
      </header>

      {/* Content */}
      <main className="flex-1 px-4 py-5 pb-24 max-w-lg w-full mx-auto">
        <AnimatePresence mode="wait">
          {tab === 'board' && !selectedJobId && (
            <motion.div key="board" initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -6 }}>
              <div className="mb-4 flex items-center justify-between">
                <h1 className="display text-xl font-bold" style={{ color: 'var(--ink)' }}>Job Board</h1>
                <GhostButton label="Post a Job" onClick={() => setTab('post')} small />
              </div>
              <JobBoard onOpenJob={handleOpenJob} />
            </motion.div>
          )}
          {tab === 'board' && selectedJobId !== null && (
            <motion.div key={`job-${selectedJobId.toString()}`} initial={{ opacity: 0, x: 16 }} animate={{ opacity: 1, x: 0 }} exit={{ opacity: 0, x: -16 }}>
              <JobDetail jobId={selectedJobId} onBack={handleBack} />
            </motion.div>
          )}
          {tab === 'post' && (
            <motion.div key="post" initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -6 }}>
              <PostJob onBack={() => handleTabChange('board')} />
            </motion.div>
          )}
          {tab === 'reputation' && (
            <motion.div key="reputation" initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -6 }}>
              <div className="mb-4">
                <h1 className="display text-xl font-bold" style={{ color: 'var(--ink)' }}>Reputation</h1>
                <p className="mt-0.5 text-sm" style={{ color: 'var(--muted)' }}>Onchain reputation scores for freelancers and clients.</p>
              </div>
              <ReputationView />
            </motion.div>
          )}
        </AnimatePresence>
      </main>

      {/* Bottom nav */}
      <nav className="fixed bottom-0 inset-x-0 z-40 flex" style={glass.nav}>
        <div className="flex w-full max-w-lg mx-auto">
          <NavTab active={tab === 'board'} label="Board" icon={Briefcase} onClick={() => handleTabChange('board')} />
          <NavTab active={tab === 'post'} label="Post Job" icon={Plus} onClick={() => handleTabChange('post')} />
          <NavTab active={tab === 'reputation'} label="Reputation" icon={Star} onClick={() => handleTabChange('reputation')} />
        </div>
      </nav>
    </div>
  )
}
