// Only directly observed, committed context is evidence. No history/HTTP/DB fallback.
import { createHash, randomUUID } from "node:crypto";

const PREFIX = "authorization-evidence/v1/";
const MAX_SCHEMA_REFS = 16_384;
// Keep the retained authority window bounded well below MAX_SCHEMA_REFS so a
// very long session degrades older refs to restriction-only instead of turning
// the checkpoint into an unreadable (>16384 refs) record.
const MAX_RETAINED_REFS = 8_192;
const CAPACITY_REASONS = new Set(["evidence_limit", "persist_limit", "task_boundary_incomplete"]);
export const isCapacityReason = (reason) => CAPACITY_REASONS.has(reason);
export function evidenceLimits(options = {}) {
  const defaults = { maxRecords: 1024, maxStoredChars: 1_048_576, scanPageSize: 128, maxScanPages: 32,
    scanTimeoutMs: 5000, maxPromptChars: 262_144 };
  return Object.fromEntries(Object.entries(defaults).map(([key, fallback]) =>
    [key, Number.isFinite(Number(options?.[key])) && Number(options[key]) > 0 ? Math.max(1, Math.floor(Number(options[key]))) : fallback]));
}
const hash = (value) => createHash("sha256").update(JSON.stringify(value)).digest("hex");
const sessionPrefix = (id) => `${PREFIX}s/${encodeURIComponent(id)}/`;
const proofKey = (id, ref) => `${PREFIX}proof/${encodeURIComponent(id)}/${ref}`;

// A failed/unstable observation is not evidence of a history mutation.
class PendingObservation extends Error {
  constructor(reason, confirmation = null) { super(reason); this.confirmation = confirmation; }
}
const TRANSIENT_REASONS = new Set(["observer_continuity_unknown", "concurrent_snapshot", "context_unavailable", "storage_failure", "storage_unavailable",
  "scan_page_limit", "scan_time_limit", "prompt_limit", "context_window_limit"]);

async function scanWithin(promise, ms) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new PendingObservation("scan_time_limit")), ms);
      timer.unref?.();
    })]);
  } finally { clearTimeout(timer); }
}

export function isSystemUser(message) {
  return message?.synthetic === true || message?.metadata?.synthetic === true || message?.metadata?.internal === true ||
    ["agent", "subagent", "internal", "system"].includes(message?.metadata?.source) ||
    /^\s*(?:\[BACKGROUND TASK |\[Background Job Board\]|<system-reminder>|\[system-reminder\]|\[oh-my-opencode|\[OMO|\[SLIM|You are a subagent spawned by another session\.)/i.test(message?.text ?? "");
}

// Question prompts are agent-authored, answers alone are user input. Keep both, never
// promote a pending tool result or a child-session answer into root-user authority.
function originals(sessionID, messages, agentContext) {
  const records = [];
  let malformed = false;
  for (const message of messages) {
    const time = message?.time?.created;
    const valid = typeof message?.id === "string" && message.id !== "" && Number.isFinite(time);
    const add = (kind, text, suffix = "", timestamp = time) => {
      if (!valid || !Number.isFinite(timestamp)) { malformed = true; return; }
      const record = { sessionID, messageID: message.id, time: timestamp, kind, text, suffix };
      records.push({ ...record, ref: hash(record) });
    };
    if (message?.type === "user" && (agentContext || !isSystemUser(message)) && typeof message.text === "string" && message.text.trim()) {
      add(agentContext ? "agent task" : "user", message.text);
    }
    if (message?.type !== "assistant") continue;
    for (const part of message.content ?? []) {
      if (part?.type !== "tool" || part.name !== "question" || part.state?.status !== "completed") continue;
      if (!Number.isFinite(part.time?.completed)) { malformed = true; continue; }
      const answers = part.state.metadata?.answers ?? part.state.output?.answers;
      const content = part.state.content ?? part.state.output?.content;
      // The host's completed question result includes the questions in its content.
      const result = answers !== undefined ? { questions: part.input ?? part.state.input ?? null, answers }
        : content ? { questions: part.input ?? part.state.input ?? null, result: content } : null;
      if (result) add(agentContext ? "agent task via question" : "user via question", JSON.stringify(result), String(part.id ?? part.callID ?? "question"), part.time.completed);
    }
  }
  return { records, malformed };
}

export async function createEvidenceStore(storage, timeout, options = {}) {
  const limits = evidenceLimits(options);
  const usable = ["get", "set", "remove", "scan"].every((name) => typeof storage?.[name] === "function");
  let available = usable;
  let failure = usable ? null : "storage_unavailable";
  let streamOK = false;
  let globalEpoch = 0;
  let failureEpoch = 0;
  const owner = randomUUID();
  const epochs = new Map();
  const revisions = new Map();
  const queues = new Map();
  const memory = new Map();
  const faults = new Map();
  const knownRecords = new Map();
  const compactions = new Map();
  const invalidReceipts = new Set();
  const touch = (id) => epochs.set(id, (epochs.get(id) ?? 0) + 1);
  const revise = (id) => revisions.set(id, (revisions.get(id) ?? 0) + 1);
  const fault = (id, reason) => {
    if (!faults.has(id)) faults.set(id, new Set());
    if (faults.get(id).has(reason)) return false;
    faults.get(id).add(reason);
    return true;
  };
  const call = async (fn) => {
    try { return await timeout(fn()); }
    catch (error) {
      available = false;
      failure = "storage_failure";
      failureEpoch += 1;
      throw error;
    }
  };
  // A probe verifies write/read availability, not just the presence of method names.
  if (available) {
    const key = `${PREFIX}probe/${randomUUID()}`;
    try {
      await call(() => storage.set(key, { probe: key }));
      if ((await call(() => storage.get(key)))?.probe !== key) throw new Error("storage probe mismatch");
      await call(() => storage.remove(key));
    } catch { available = false; failure = "storage_failure"; }
  }
  const serial = (id, fn) => {
    const next = (queues.get(id) ?? Promise.resolve()).then(fn, fn);
    queues.set(id, next.catch(() => {}));
    return next;
  };
  const write = async (full, value) => {
    memory.set(full, value);
    if (available) await call(() => storage.set(full, value));
  };
  const put = (id, key, value) => write(sessionPrefix(id) + key, value);
  const load = async (id, counts) => {
    const prefix = sessionPrefix(id);
    if (!available) return [...memory].filter(([key]) => key.startsWith(prefix)).map(([key, value]) => ({ key, value }));
    const entries = [];
    const keys = new Set();
    const cursors = new Set();
    const deadline = Date.now() + limits.scanTimeoutMs;
    let after;
    for (let n = 0; n < limits.maxScanPages; n += 1) {
      if (Date.now() >= deadline) throw new PendingObservation("scan_time_limit");
      let page;
      try { page = await scanWithin(storage.scan({ prefix, after, limit: limits.scanPageSize }), deadline - Date.now()); }
      catch (error) { if (error instanceof PendingObservation) throw error; return call(() => Promise.reject(error)); }
      counts.scanPages += 1;
      if (Date.now() >= deadline) throw new PendingObservation("scan_time_limit");
      if (!Array.isArray(page?.entries)) throw new Error("storage_corrupt");
      for (const entry of page.entries) {
        if (!entry || typeof entry.key !== "string" || !entry.key.startsWith(prefix) || entry.value?.sessionID !== id || keys.has(entry.key)) {
          throw new Error("storage_corrupt");
        }
        keys.add(entry.key);
        entries.push(entry);
      }
      counts.scanEntries = entries.length;
      if (!page.next) { counts.scanComplete = true; return entries; }
      if (typeof page.next !== "string" || cursors.has(page.next)) throw new Error("storage_corrupt");
      cursors.add(page.next);
      after = page.next;
    }
    throw new PendingObservation("scan_page_limit");
  };
  const checkpoint = async (id) => {
    try {
      const value = available ? await call(() => storage.get(sessionPrefix(id) + "checkpoint")) : memory.get(sessionPrefix(id) + "checkpoint");
      return { value: value ?? null, token: hash(value ?? null) };
    } catch { return { value: null, token: null }; }
  };
  const unchangedCheckpoint = async (id, token) => {
    const current = await checkpoint(id);
    if (!available) throw new PendingObservation("storage_failure");
    if (current.token !== token) throw new PendingObservation("concurrent_snapshot");
  };
  const barrier = async (id, reason, missing = null) => {
    const key = `barrier/${encodeURIComponent(reason)}${missing ? `/${missing}` : ""}`;
    const full = sessionPrefix(id) + key;
    if (memory.has(full)) return { key: full, value: memory.get(full) };
    if (available) {
      const existing = await call(() => storage.get(full));
      if (existing !== undefined && existing !== null) {
        if (existing.kind !== "barrier" || existing.sessionID !== id || existing.reason !== reason) throw new Error("storage_corrupt");
        memory.set(full, existing);
        return { key: full, value: existing };
      }
    }
    revise(id);
    // One monotonic barrier per reason, not per observation. Concurrent timestamps
    // do not affect semantics: ANY barrier disables positive authority for the
    // whole session. Known text remains restriction-only; there is no time cutoff.
    const value = { kind: "barrier", sessionID: id, cutoff: Date.now(), reason, ...(missing ? { missing: [missing] } : {}) };
    await put(id, key, value);
    return { key: full, value };
  };
  const api = {
    limits,
    status: () => ({ durable: available, backend: available ? "ctx.storage" : "memory", eventStream: streamOK, reason: failure, limits }),
    checkpoint,
    touch,
    compactionEvent(id, event) {
      if (event.type === "session.compaction.failed") { compactions.delete(id); invalidReceipts.add(id); return; }
      if (event.type === "session.compaction.started") {
        const messageID = event.data?.inputID ?? (typeof event.id === "string" && event.id.startsWith("evt_")
          ? event.id.replace(/^evt_/, "msg_") : null);
        // v2 message-updater: inputID (manual), otherwise ID.fromEvent(event.id).
        compactions.set(id, { messageID, ended: false });
      } else if (event.type === "session.compaction.ended" && compactions.has(id)) compactions.get(id).ended = true;
    },
    stream(healthy) {
      streamOK = healthy;
      globalEpoch += 1;
      if (!healthy) {
        for (const id of epochs.keys()) void api.invalidate(id, "event_stream_gap");
      }
    },
    stamp(ids) { return { global: globalEpoch, failure: failureEpoch, sessions: ids.map((id) => [id, epochs.get(id) ?? 0, revisions.get(id) ?? 0]) }; },
    unchangedEvents(stamp) { return stamp && stamp.global === globalEpoch && stamp.sessions.every(([id, n]) => (epochs.get(id) ?? 0) === n); },
    current(stamp) { return api.unchangedEvents(stamp) && stamp.failure === failureEpoch &&
      stamp.sessions.every(([id, _event, revision]) => (revisions.get(id) ?? 0) === revision); },
    invalidate(id, reason) {
      if (reason === "observer_continuity_unknown") {
        // Legacy runtime-local doubt, not a destructive event or durable barrier.
        if (fault(id, reason)) revise(id);
        return Promise.resolve();
      }
      // Cache failures invalidate grants, but are not new user instructions: they
      // must not accidentally turn the ordinary low/medium path into a global lock.
      if (reason === "event_capture_failed" || reason === "compaction_capture_failed") revise(id);
      else touch(id);
      fault(id, reason);
      compactions.delete(id);
      invalidReceipts.add(id);
      return serial(id, async () => {
        try { await barrier(id, reason); } catch { /* faults still prevents reuse */ }
      });
    },
    observe(id, info, messages, agentContext, preCompaction = false, capture = {}) {
      if (!epochs.has(id)) epochs.set(id, 0);
      return serial(id, async () => {
        const reasons = [...(faults.get(id) ?? [])];
        let records = [...(knownRecords.get(id)?.values() ?? [])];
        let changed = false;
        let confirmation = null;
        let retry = false;
        let checkpointToken = capture.before?.token;
        let eligible = new Set();
        let hasBarrier = false;
        let actionCandidates = [];
        let capacityRecovered = null;
        const counts = { sessionID: id, scanPages: 0, scanEntries: 0, scanComplete: false, storedRecords: null, storedChars: null,
          observedRecords: null, observedChars: null, unsavedRecords: 0, proofReads: 0, limitsReached: [], legacyLimitPresent: false,
          contextMessages: Array.isArray(messages) ? messages.length : null };
        try {
          if (info?.id !== id || !Array.isArray(messages)) throw new PendingObservation("context_unavailable");
          const entries = await load(id, counts);
          let checkpoint = null;
          // Keep previously observed but not persisted text as restrictive context;
          // a failed capacity write must not silently erase a known prohibition.
          const byRef = new Map(knownRecords.get(id));
          const stored = new Set();
          const legacy = new Set();
          const barriers = [];
          for (const { key, value } of entries) {
            if (key.endsWith("/checkpoint")) {
              if (value.kind !== "checkpoint" || !Array.isArray(value.ids) || value.ids.length > MAX_SCHEMA_REFS ||
                  value.ids.some((id) => typeof id !== "string" || !id) || !Array.isArray(value.visible) ||
                  value.visible.length > MAX_SCHEMA_REFS ||
                  value.visible.some((ref) => typeof ref !== "string" || !/^[a-f0-9]{64}$/.test(ref)) ||
                  typeof value.owner !== "string" || typeof value.revision !== "string") throw new Error("storage_corrupt");
              if (value.retained !== undefined && (!Array.isArray(value.retained) || value.retained.length > MAX_SCHEMA_REFS ||
                  value.retained.some((ref) => typeof ref !== "string" || !/^[a-f0-9]{64}$/.test(ref)))) throw new Error("storage_corrupt");
              if (value.sourceUpdatedAt != null && !Number.isFinite(value.sourceUpdatedAt)) throw new Error("storage_corrupt");
              if (value.compactionID != null && (typeof value.compactionID !== "string" || !value.compactionID)) throw new Error("storage_corrupt");
              if (value.prepared != null && (!Array.isArray(value.prepared.ids) || value.prepared.ids.length > MAX_SCHEMA_REFS ||
                  value.prepared.ids.some((id) => typeof id !== "string" || !id) ||
                  !Array.isArray(value.prepared.visible) || value.prepared.visible.length > MAX_SCHEMA_REFS ||
                  value.prepared.visible.some((ref) => typeof ref !== "string" || !/^[a-f0-9]{64}$/.test(ref)) ||
                  typeof value.prepared.revision !== "string")) throw new Error("storage_corrupt");
              checkpoint = value;
            } else if (value.kind === "barrier" && Number.isFinite(value.cutoff) && value.cutoff >= 0 && typeof value.reason === "string") {
              if (value.missing !== undefined && (!Array.isArray(value.missing) || value.missing.some((ref) => typeof ref !== "string" || !/^[a-f0-9]{64}$/.test(ref)))) throw new Error("storage_corrupt");
              barriers.push({ key, value, ref: hash({ key, value }) });
              if (value.reason === "evidence_limit") counts.legacyLimitPresent = true;
              memory.set(key, value);
            }
            else if (value.kind === "record" && value.record?.sessionID === id &&
              typeof value.record.messageID === "string" && value.record.messageID && Number.isFinite(value.record.time) &&
              ["user", "user via question", "agent task", "agent task via question"].includes(value.record.kind) && typeof value.record.suffix === "string" &&
              typeof value.record.text === "string" &&
              key === `${sessionPrefix(id)}record/${value.record.ref}` && value.record.ref === hash({
              sessionID: id, messageID: value.record.messageID, time: value.record.time,
              kind: value.record.kind, text: value.record.text, suffix: value.record.suffix,
            })) {
              byRef.set(value.record.ref, value.record);
              stored.add(value.record.ref);
              if (value.requiresCheckpoint !== true) legacy.add(value.record.ref);
            }
            else throw new Error("storage_corrupt");
          }
          records = [...byRef.values()];
          counts.storedRecords = stored.size;
          counts.storedChars = records.filter((record) => stored.has(record.ref)).reduce((sum, record) => sum + record.text.length, 0);
          if (checkpoint?.retained?.some((ref) => !stored.has(ref))) throw new Error("storage_corrupt");
          knownRecords.set(id, byRef);
          checkpointToken = hash(checkpoint);
          // Context was read AFTER capture.before. A writer that advanced the
          // checkpoint in between is a retry, never a deletion inferred from the
          // older context. Preserve the newer checkpoint verbatim.
          if (capture.before && capture.before.token !== checkpointToken) throw new PendingObservation("concurrent_snapshot");
          eligible = new Set(checkpoint?.retained ?? legacy);
          let previousProof = null;
          if (checkpoint?.capacityRecovery) {
            if (typeof checkpoint.capacityRecovery !== "string" || !/^[a-f0-9]{64}$/.test(checkpoint.capacityRecovery)) throw new Error("storage_corrupt");
            const key = proofKey(id, checkpoint.capacityRecovery);
            previousProof = available ? await call(() => storage.get(key)) : memory.get(key);
            counts.proofReads += 1;
            if (!previousProof || previousProof.kind !== "capacity-recovery" || previousProof.sessionID !== id ||
                !Array.isArray(previousProof.barrierRefs) || previousProof.barrierRefs.length > MAX_SCHEMA_REFS ||
                !Array.isArray(previousProof.refs) || previousProof.refs.length > MAX_SCHEMA_REFS ||
                !Array.isArray(previousProof.ids) || previousProof.ids.length > MAX_SCHEMA_REFS ||
                previousProof.ids.some((value) => typeof value !== "string" || !value) ||
                [...previousProof.barrierRefs, ...previousProof.refs].some((ref) => typeof ref !== "string" || !/^[a-f0-9]{64}$/.test(ref))) throw new Error("storage_corrupt");
            const { id: proofID, ...body } = previousProof;
            if (proofID !== checkpoint.capacityRecovery || proofID !== hash(body)) throw new Error("storage_corrupt");
          }
          if (checkpoint?.capacityRecovery && (!previousProof || previousProof.refs.some((ref) => !stored.has(ref) || !eligible.has(ref)))) throw new Error("storage_corrupt");
          capacityRecovered = previousProof?.id ?? null;
          const activeBarriers = barriers.filter((entry) => !CAPACITY_REASONS.has(entry.value.reason) || !previousProof?.barrierRefs.includes(entry.ref));
          hasBarrier = activeBarriers.length > 0;
          reasons.push(...activeBarriers.map((entry) => entry.value.reason));
          const observed = originals(id, messages, agentContext);
          counts.observedRecords = observed.records.length;
          counts.observedChars = observed.records.reduce((sum, record) => sum + record.text.length, 0);
          if (observed.malformed) reasons.push("source_identity_missing");
          const ids = messages.map((message) => message?.id);
          if (ids.some((value) => typeof value !== "string" || !value)) reasons.push("context_identity_missing");
          if (ids.length > MAX_SCHEMA_REFS) throw new PendingObservation("context_window_limit");
          const visible = observed.records.map((record) => record.ref);
          const compactionID = messages.findLast((message) => message.type === "compaction" && message.status === "completed")?.id ?? null;
          const revision = hash({ time: info.time, tokens: info.tokens, cost: info.cost, count: info.metadata?.messageCount });
          const disappeared = checkpoint && (checkpoint.ids.some((value, index) => ids[index] !== value) ||
            checkpoint.visible.some((value) => !visible.includes(value)));
          const revised = records.some((original) => ids.includes(original.messageID) && !visible.includes(original.ref));
          let prepared = invalidReceipts.has(id) ? null : checkpoint?.prepared ?? null;
          const transition = compactions.get(id);
          const marker = transition?.messageID && messages.find((message) => message.type === "compaction" && message.id === transition.messageID);
          const receiptValid = prepared && Array.isArray(prepared.ids) && Array.isArray(prepared.visible) &&
            prepared.ids.every((value) => checkpoint.ids.includes(value)) && prepared.visible.every((ref) => byRef.has(ref));
          const knownTransition = receiptValid && marker && ["running", "completed"].includes(marker.status);
          const blockingReasons = reasons.filter((reason) => reason !== "observer_continuity_unknown");
          const onlyCapacity = hasBarrier && activeBarriers.every((entry) => CAPACITY_REASONS.has(entry.value.reason)) &&
            blockingReasons.every((reason) => CAPACITY_REASONS.has(reason));
          const knownCompaction = knownTransition && transition.ended && marker.status === "completed" &&
            ((!hasBarrier && blockingReasons.length === 0) || onlyCapacity);
          const compactionCovered = knownCompaction ? [...prepared.visible] : [];
          const awaitingEnd = disappeared && knownTransition && marker.status === "completed" && !transition.ended;
          const identityChanged = checkpoint && (checkpoint.parentID !== (info.parentID ?? null) ||
            (checkpoint.revert ?? null) !== (JSON.stringify(info.revert) ?? null));
          const discontinuous = revised || (disappeared && !knownCompaction && !awaitingEnd) || identityChanged || (!checkpoint && info.revert);
          const sameWindowDeletion = !knownCompaction && !awaitingEnd && ((checkpoint?.compactionID === compactionID && disappeared) ||
            (compactionID === null && records.some((record) => !ids.includes(record.messageID))));
          // time/tokens/cost/count/owner never establish a history fault. A known
          // older projector watermark can only defer judgment, not authorize it.
          if (discontinuous && !knownTransition && Number.isFinite(info.time?.updated) && Number.isFinite(checkpoint?.sourceUpdatedAt) &&
              info.time.updated < checkpoint.sourceUpdatedAt) throw new PendingObservation("concurrent_snapshot");
          if ((!hasBarrier && !blockingReasons.length && discontinuous) ||
              (onlyCapacity && (revised || identityChanged || info.revert || sameWindowDeletion))) {
            const candidate = hash({ checkpointToken, ids, visible, parentID: info.parentID ?? null, revert: info.revert ?? null });
            if (!capture.fresh || capture.confirmation !== candidate) {
              throw new PendingObservation("concurrent_snapshot", capture.fresh ? candidate : null);
            }
            await unchangedCheckpoint(id, checkpointToken);
            await barrier(id, "history_discontinuity");
            hasBarrier = true;
            reasons.push("history_discontinuity");
            prepared = null;
          } else if (!hasBarrier && !blockingReasons.length && !awaitingEnd && !discontinuous && reasons.includes("observer_continuity_unknown")) {
            if (!capture.fresh) throw new PendingObservation("concurrent_snapshot");
            await unchangedCheckpoint(id, checkpointToken);
            faults.get(id)?.delete("observer_continuity_unknown");
            reasons.splice(0, reasons.length); // Only the verified local reason, never durable barriers.
          }
          if (knownCompaction) prepared = null; // Clear only the proposed checkpoint, not the live receipt yet.
          if (marker?.status === "failed") {
            prepared = null;
            if (compactions.get(id) === transition) { compactions.delete(id); invalidReceipts.add(id); }
          }
          const missing = [];
          for (const record of observed.records) {
            if (stored.has(record.ref)) continue;
            if (stored.size >= limits.maxRecords || counts.storedChars + record.text.length > limits.maxStoredChars) {
              if (stored.size >= limits.maxRecords) counts.limitsReached.push("persist_records");
              if (counts.storedChars + record.text.length > limits.maxStoredChars) counts.limitsReached.push("persist_chars");
              // Preserve the directly visible text for this review, but do not
              // pretend it is durable. A bounded witness records what was missed.
              byRef.set(record.ref, record);
              missing.push(record.ref);
              continue;
            }
            await put(id, `record/${record.ref}`, { kind: "record", sessionID: id, requiresCheckpoint: true, record });
            byRef.set(record.ref, record);
            stored.add(record.ref);
            counts.storedChars += record.text.length;
            changed = true;
          }
          records = [...byRef.values()];
          counts.storedRecords = stored.size;
          counts.unsavedRecords = missing.length;
          if (missing.length) {
            reasons.push("persist_limit");
            for (const ref of missing) {
              const entry = await barrier(id, "persist_limit", ref);
              barriers.push({ ...entry, ref: hash(entry) });
            }
            hasBarrier = true;
          }
          if (agentContext && reasons.some((reason) => CAPACITY_REASONS.has(reason))) reasons.push("task_boundary_incomplete");
          const capacityEntries = barriers.filter((entry) => CAPACITY_REASONS.has(entry.value.reason));
          // Recovery is a proof of coverage, NOT "the quota is larger now". The
          // last trusted window must bridge to the current one, all uncheckpointed
          // stored originals must still be observable (or covered by the receipt),
          // and every missing-ref witness must now be present verbatim.
          const covered = new Set([...(checkpoint?.retained ?? checkpoint?.visible ?? []), ...visible, ...compactionCovered]);
          const capacityOnly = reasons.length > 0 && capacityEntries.length > 0 && barriers.every((entry) => CAPACITY_REASONS.has(entry.value.reason)) &&
            reasons.every((reason) => CAPACITY_REASONS.has(reason));
          const windowCovered = knownCompaction || (checkpoint && (checkpoint.compactionID !== undefined
            ? checkpoint.compactionID === compactionID : compactionID === null ||
              (messages[0]?.type === "compaction" && messages[0]?.status === "completed" && checkpoint.ids[0] === compactionID)));
          const canRecover = capacityOnly && checkpoint && windowCovered && !info.revert && !discontinuous && !awaitingEnd && capture.fresh && counts.scanComplete &&
            available && streamOK && !missing.length && [...byRef.keys()].every((ref) => stored.has(ref) && covered.has(ref)) &&
            capacityEntries.every((entry) => (entry.value.missing ?? []).every((ref) => covered.has(ref) && stored.has(ref)));
          if (canRecover) {
            await unchangedCheckpoint(id, checkpointToken);
            const body = { kind: "capacity-recovery", sessionID: id, barrierRefs: [...new Set(capacityEntries.map((entry) => entry.ref))].sort(),
              fromCheckpoint: checkpointToken, compactionID, ids, refs: [...byRef.keys()].sort(), sourceUpdatedAt: info.time?.updated ?? null };
            const proofID = hash(body);
            // Separate from the v1 source scan: older readers must not mistake a
            // new proof record kind for a corrupt original. Never delete barriers.
            await write(proofKey(id, proofID), { ...body, id: proofID });
            capacityRecovered = proofID;
            for (const reason of CAPACITY_REASONS) faults.get(id)?.delete(reason);
            reasons.splice(0, reasons.length);
            hasBarrier = false; // The original barrier entries remain unchanged on disk.
            eligible = covered;
          }
          if (capacityOnly && !canRecover && !agentContext && !info.parentID && !info.revert && !identityChanged &&
              !revised && counts.scanComplete && available && streamOK && !observed.malformed) {
            const lastOpaque = messages.findLastIndex((message) => message.type === "compaction" && message.status === "completed");
            actionCandidates = observed.records.filter((record) =>
              ["user", "user via question"].includes(record.kind) && messages.findIndex((message) => message.id === record.messageID) > lastOpaque)
              .map(({ sessionID, messageID, time, ref }) => ({ sessionID, messageID, time, ref }));
          }
          if (preCompaction && !reasons.length) {
            prepared = { ids: [...ids], visible: [...visible], revision };
            invalidReceipts.delete(id);
          }
          if (reasons.length) {
            for (const reason of new Set(reasons)) if (reason !== "observer_continuity_unknown" && !CAPACITY_REASONS.has(reason) && !TRANSIENT_REASONS.has(reason)) await barrier(id, reason);
          } else if (!awaitingEnd) {
            // Recheck after record writes. Without CAS the final get/set interval
            // remains a TOCTOU, but we never overwrite a KNOWN advanced snapshot.
            await unchangedCheckpoint(id, checkpointToken);
            eligible = new Set([...eligible, ...visible]);
            if (eligible.size > MAX_RETAINED_REFS) eligible = new Set([...eligible].slice(-MAX_RETAINED_REFS));
            const next = { kind: "checkpoint", sessionID: id, parentID: info.parentID ?? null,
              ids, visible, retained: [...eligible], prepared, compactionID, revert: JSON.stringify(info.revert) ?? null, revision, owner,
              ...(capacityRecovered ? { capacityRecovery: capacityRecovered } : {}),
              sourceUpdatedAt: Number.isFinite(info.time?.updated)
                ? Math.max(info.time.updated, checkpoint?.sourceUpdatedAt ?? info.time.updated) : checkpoint?.sourceUpdatedAt ?? null, at: Date.now() };
            await put(id, "checkpoint", next);
            checkpointToken = hash(next);
            // A detected concurrent checkpoint change throws before this commit.
            // Keep the completed transition available for that fresh retry. An
            // event may also install a NEW transition while put() is pending.
            if (knownCompaction && compactions.get(id) === transition) {
              compactions.delete(id);
              if (!next.prepared) invalidReceipts.add(id); // Do not invalidate a newly prepared hook receipt.
            }
          }
          if (awaitingEnd) reasons.push("compaction_pending");
        } catch (error) {
          const temporary = error instanceof PendingObservation || !available;
          const reason = !available ? failure : temporary ? error.message : error.message === "storage_corrupt" ? error.message : "capture_failed";
          reasons.push(reason);
          if (["scan_page_limit", "scan_time_limit", "context_window_limit"].includes(reason)) counts.limitsReached.push(reason);
          if (temporary) {
            retry = reason === "concurrent_snapshot";
            confirmation = error.confirmation ?? null;
          } else {
            const newFault = fault(id, reason);
            compactions.delete(id);
            if (newFault) revise(id);
            try { await barrier(id, reason); } catch { /* Memory-only fault still blocks authority. */ }
          }
          records = [...(knownRecords.get(id)?.values() ?? [])]; // Restrictions only, NEVER stale positive authority.
          actionCandidates = [];
        }
        if (!available) reasons.push(failure);
        if (!streamOK) reasons.push("event_stream_unavailable");
        counts.limitsReached = [...new Set(counts.limitsReached)];
        if (!counts.scanComplete) { counts.storedRecords = null; counts.storedChars = null; }
        records = records.map((record) => ({ ...record, parentID: info?.parentID ?? null,
          authority: agentContext || record.kind.startsWith("agent task") ? "task-boundary" : actionCandidates.some((anchor) => anchor.ref === record.ref)
            ? "action-anchor-candidate" : reasons.length || !eligible.has(record.ref) ? "restriction-reference-only" : "user-authorization" }));
        records.sort((a, b) => a.time - b.time || a.messageID.localeCompare(b.messageID) || a.ref.localeCompare(b.ref));
        return { sessionID: id, records, changed, retry, confirmation, checkpointToken, hasBarrier, counts, capacityRecovered, actionCandidates,
          // Fresh reads cover the entire suffix. Only authority-bearing inputs
          // and its opaque-window boundary change its semantic version; normal
          // assistant/tool progress must not invalidate every retry's grant.
          suffixProof: actionCandidates.length ? hash({ compactionID: messages.findLast((message) => message.type === "compaction" && message.status === "completed")?.id ?? null,
            visible: originals(id, messages, false).records.map((record) => record.ref), actionCandidates }) : null,
          capacityOnly: reasons.length > 0 && reasons.every((reason) => CAPACITY_REASONS.has(reason)) && actionCandidates.length > 0,
          transient: reasons.length > 0 && reasons.every((reason) => TRANSIENT_REASONS.has(reason)),
          incomplete: reasons.length > 0, reasons: [...new Set(reasons)],
          sourceVersion: hash({ parentID: info?.parentID ?? null, users: Array.isArray(messages) ? messages.filter((message) => message.type === "user") : null }),
          historyBeforeObservation: "unknown", durable: available };
      });
    },
  };
  return api;
}

export function evidenceBundle(views, stamp, incomplete = false, limits = evidenceLimits()) {
  const records = views.flatMap((view) => view.records).sort((a, b) => a.time - b.time || a.messageID.localeCompare(b.messageID) || a.ref.localeCompare(b.ref));
  const jsonLines = records.map((record) => JSON.stringify(record)).join("\n");
  const over = jsonLines.length > limits.maxPromptChars;
  const reasons = [...new Set(views.flatMap((view) => view.reasons))];
  if (over) reasons.push("prompt_limit");
  if (incomplete) reasons.push("parent_chain_incomplete");
  const safeRecords = over ? [] : records;
  const actionOnly = !over && !incomplete && reasons.length > 0 && reasons.every(isCapacityReason) && views.some((view) => view.capacityOnly) &&
    views.every((view) => view.capacityOnly || !view.incomplete);
  const actionCandidates = actionOnly ? views.flatMap((view) => view.actionCandidates ?? []) : [];
  const coverage = { evidenceIncomplete: incomplete || over || views.some((view) => view.incomplete),
    historyBeforeObservation: "unknown", durable: views.length > 0 && views.every((view) => view.durable), reasons,
    actionOnly, capacityRecovered: views.map((view) => view.capacityRecovered).filter(Boolean) };
  const reference = ({ sessionID, messageID, time, ref, authority }) => ({ sessionID, messageID, time, ref, authority });
  const refs = safeRecords.filter((record) => record.authority === "user-authorization").map(reference);
  const referenceRefs = safeRecords.filter((record) => record.authority !== "user-authorization").map(reference);
  coverage.recovery = over || reasons.some((reason) => ["scan_page_limit", "scan_time_limit", "context_window_limit"].includes(reason)) ? "increase_evidence_budget"
    : actionOnly ? "action_only_review" : reasons.length && reasons.every((reason) => CAPACITY_REASONS.has(reason)) ? "capacity_coverage_needed"
    : views.some((view) => view.hasBarrier) || reasons.some((reason) => !TRANSIENT_REASONS.has(reason) && !["compaction_pending", "context_changed_during_capture", "parent_chain_changed"].includes(reason))
    ? "new_session_or_maintenance" : coverage.evidenceIncomplete ? "retry_latest" : refs.length ? "none" : "user_confirmation";
  // Counts explain which quota fired, but changing scan page counts/metadata is
  // not a change in authority. Hash semantic coverage separately from telemetry.
  const semanticCoverage = { ...coverage };
  coverage.budgets = { limits, promptJSONChars: jsonLines.length, knownRecords: records.length,
    knownRawChars: records.reduce((sum, record) => sum + record.text.length, 0),
    limitsReached: [...new Set([...views.flatMap((view) => view.counts?.limitsReached ?? []), ...(over ? ["prompt_json_chars"] : [])])],
    sources: views.map((view) => ({ ...view.counts, capacityRecovered: view.capacityRecovered ?? null })) };
  const sources = views.map(({ sessionID, sourceVersion }) => ({ sessionID, sourceVersion }));
  const texts = safeRecords.flatMap((record) => {
    if (!record.kind.endsWith("via question")) return [record.text];
    const fragments = [record.text];
    const pending = [JSON.parse(record.text)];
    while (pending.length) {
      const value = pending.pop();
      if (typeof value === "string") fragments.push(value);
      else if (value && typeof value === "object") {
        for (const [key, child] of Object.entries(value)) if (key !== "type") pending.push(child);
      }
    }
    return fragments;
  });
  const retryState = { incomplete: coverage.evidenceIncomplete, reasons: [...reasons].sort() };
  return { stamp, coverage, refs, referenceRefs, actionCandidates, texts, version: hash({ coverage: semanticCoverage, records: safeRecords,
    sources, suffixProofs: views.map((view) => view.suffixProof) }), retryVersion: hash({ refs, referenceRefs, sources, limits, actionOnly, durable: coverage.durable, retryState }),
    text: `AUTHORIZATION EVIDENCE (verbatim observations, chronological; separate from recent-context truncation):\n` +
      JSON.stringify(coverage) + "\n" + safeRecords.map((record) => JSON.stringify(record)).join("\n") };
}
