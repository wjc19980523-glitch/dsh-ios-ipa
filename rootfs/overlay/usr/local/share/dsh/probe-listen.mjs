// probe-listen.mjs — CI 诊断插桩，区分「从未监听」与「监听后被关闭」。
//
// 正式 IPA 不会加载它：dsh-serve 只在 DSH_PROBE_LISTEN 环境变量非空时才用
// --import 把它注入，而那个变量只在 tests/rootfs-test.sh 里设置。文件随 rootfs
// 分发但未启用时零副作用（不被 import）。
//
// 它 monkey-patch net.Server.prototype.listen/close（http.Server 继承自
// net.Server，所以 http.createServer().listen 也走这里），打印：
//   1. LISTEN 是否被调用、port/host 参数是什么（验证 config 注入）
//   2. LISTENING 事件是否触发、address() 与 listening 状态（验证监听地址）
//   3. CLOSE 是否被调用、调用栈（回答「监听后被谁关闭」）
//
// 这三条把「从未监听」和「监听后又被 close 掉」一次区分开，而不是再猜一轮。
import net from "node:net";
import fs from "node:fs";
import process from "node:process";

// The real-time guarantee comes from the *filter* (perl $|=1), not from node:
// node's console.log is already synchronous to a pipe/file (verified: a line
// is visible immediately). The only buffering layer was sed in the pipeline.
// Keep setBlocking as a harmless belt-and-braces; it does not change output.
for (const stream of [process.stdout, process.stderr]) {
    if (stream && stream._handle && typeof stream._handle.setBlocking === "function") {
        stream._handle.setBlocking(true);
    }
}

const origListen = net.Server.prototype.listen;
const origClose = net.Server.prototype.close;
let seq = 0;

function countFds() {
  try {
    return fs.readdirSync("/proc/self/fd").length;
  } catch {
    return -1;
  }
}
function countHandles() {
  try {
    return process._getActiveHandles().length;
  } catch {
    return -1;
  }
}

net.Server.prototype.listen = function (...args) {
  const id = ++seq;
  // fds/handles at the moment of listen: if iSH's socket forwarding breaks
  // under a large fd/socket table (the one delta left between the clean sanity
  // servers that DID reach the host and dsh, which did not), these numbers name
  // the threshold.
  console.log(`[probe] #${id} LISTEN port=${args[0]} host=${args[1]} fds=${countFds()} handles=${countHandles()}`);
  const r = origListen.apply(this, args);
  this.once("listening", () => {
    console.log(`[probe] #${id} LISTENING addr=${JSON.stringify(this.address())} listening=${this.listening}`);
  });
  this.once("close", () => {
    console.log(`[probe] #${id} CLOSE_EVENT`);
  });
  this.on("error", (e) => {
    console.log(`[probe] #${id} ERROR ${e.code || e.message}`);
  });
  return r;
};

net.Server.prototype.close = function (...args) {
  console.log(`[probe] CLOSE() listening=${this.listening} addr=${JSON.stringify(this.address())}`);
  console.log(`[probe] CLOSE stack:\n` + new Error().stack.split("\n").slice(1, 8).join("\n"));
  return origClose.apply(this, args);
};
