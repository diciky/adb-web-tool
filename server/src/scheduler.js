const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const config = require('./config');
const { executeAction } = require('./actions');

const file = path.join(config.DATA_DIR, 'schedules.json');
let jobs = [];
let timer = null;

function load() {
  try { jobs = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { jobs = []; }
}
function save() {
  try { fs.writeFileSync(file, JSON.stringify(jobs, null, 2)); } catch (e) {}
}

function matchField(val, spec) {
  if (spec === '*' || spec === '') return true;
  for (const part of spec.split(',')) {
    if (part.includes('/')) {
      const [r, step] = part.split('/');
      const st = parseInt(step, 10);
      if (r === '*' || r === '') { if (val % st === 0) return true; }
      else {
        const [a, b] = r.split('-').map(Number);
        if (val >= a && val <= b && (val - a) % st === 0) return true;
      }
    } else if (part.includes('-')) {
      const [a, b] = part.split('-').map(Number);
      if (val >= a && val <= b) return true;
    } else if (parseInt(part, 10) === val) return true;
  }
  return false;
}

function cronMatch(expr, d) {
  const f = expr.trim().split(/\s+/);
  if (f.length !== 5) return false;
  const minute = d.getMinutes();
  const hour = d.getHours();
  const dom = d.getDate();
  const month = d.getMonth() + 1;
  const dow = d.getDay();
  const dow7 = dow === 0 ? 7 : dow;
  return (
    matchField(minute, f[0]) &&
    matchField(hour, f[1]) &&
    matchField(dom, f[2]) &&
    matchField(month, f[3]) &&
    matchField(dow7, f[4])
  );
}

function computeNext(job, fromMs) {
  if (job.intervalSec) return fromMs + job.intervalSec * 1000;
  const expr = job.cron;
  if (!expr) return fromMs + 60000;
  let t = new Date(fromMs);
  t.setSeconds(0, 0);
  for (let i = 0; i < 4000000; i++) {
    if (cronMatch(expr, t)) return t.getTime();
    t = new Date(t.getTime() + 60000);
  }
  return fromMs + 86400000;
}

async function runJob(job) {
  const results = [];
  for (const serial of job.targets || []) {
    try {
      const r = await executeAction(serial, job.action, job.params || {});
      results.push({ serial, ok: r.ok, message: r.message });
    } catch (e) {
      results.push({ serial, ok: false, message: e.message });
    }
  }
  job.lastResult = results;
  job.lastResultTime = Date.now();
}

function tick() {
  const now = Date.now();
  for (const job of jobs) {
    if (job.paused) continue;
    if (!job.nextRun || now >= job.nextRun) {
      runJob(job).then(() => {
        job.lastRun = now;
        job.nextRun = computeNext(job, Date.now());
        save();
      });
    }
  }
}

function addJob(job) {
  job.id = crypto.randomUUID();
  job.paused = false;
  job.nextRun = computeNext(job, Date.now());
  jobs.push(job);
  save();
  return job;
}
function removeJob(id) {
  jobs = jobs.filter((j) => j.id !== id);
  save();
}
function list() {
  return jobs;
}
async function runNow(id) {
  const job = jobs.find((j) => j.id === id);
  if (!job) throw new Error('未找到任务');
  await runJob(job);
  job.lastRun = Date.now();
  job.nextRun = computeNext(job, Date.now());
  save();
  return job;
}

function start() {
  load();
  timer = setInterval(tick, 15000);
}

module.exports = { start, addJob, removeJob, list, runNow, computeNext };
