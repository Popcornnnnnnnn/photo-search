import assert from "node:assert/strict";
import fs from "node:fs";
import net from "node:net";
import test from "node:test";
import {
  buildDeepLink,
  companionBinaryPath,
  formatBytes,
  sendSocketRequest,
} from "../src/lib/protocol.ts";

function shortSocketPath(tag) {
  return `/tmp/ps-ray-${tag}-${process.pid}.sock`;
}

test("buildDeepLink formats asset and search URLs safely", () => {
  assert.equal(buildDeepLink("asset", { id: "photos-abc123" }), "photosearch://asset/photos-abc123");
  assert.equal(
    buildDeepLink("search", { query: "whiteboard notes", section: "uiScreenshot", time: "last30Days" }),
    "photosearch://search?q=whiteboard+notes&section=uiScreenshot&time=last30Days",
  );
  assert.equal(buildDeepLink("search", { query: "", section: "all", time: "all" }), "photosearch://search");
  assert.throws(() => buildDeepLink("asset", { id: "   " }), /Missing asset ID/);
});

test("companionBinaryPath resolves app bundle executable", () => {
  assert.equal(
    companionBinaryPath("/Applications/Photo Search.app"),
    "/Applications/Photo Search.app/Contents/MacOS/LiquidGlassDemo",
  );
  assert.equal(
    companionBinaryPath(undefined),
    "/Applications/Photo Search.app/Contents/MacOS/LiquidGlassDemo",
  );
  assert.equal(formatBytes(4941365248), "4.6 GB");
});

test("sendSocketRequest handles large payloads (>16 KB) over Unix socket", async () => {
  const sockPath = shortSocketPath("large");
  try {
    fs.unlinkSync(sockPath);
  } catch {
    // ignore missing
  }

  const bigCaption = "alpine lake ".repeat(2000);
  const server = net.createServer((conn) => {
    let incoming = "";
    conn.setEncoding("utf8");
    conn.on("data", (chunk) => {
      incoming += chunk;
      if (incoming.includes("\n")) {
        const req = JSON.parse(incoming.split("\n")[0]);
        const res = {
          ok: true,
          protocolVersion: 1,
          mode: req.mode || "lexical",
          items: [{ id: "p1", shortCaption: bigCaption }],
        };
        conn.write(`${JSON.stringify(res)}\n`);
      }
    });
  });

  await new Promise((resolve) => server.listen(sockPath, resolve));
  try {
    const res = await sendSocketRequest(sockPath, { op: "search", query: "alpine", mode: "lexical" });
    assert.equal(res.ok, true);
    assert.equal(res.items?.[0]?.shortCaption, bigCaption);
  } finally {
    await new Promise((resolve) => server.close(resolve));
    try {
      fs.unlinkSync(sockPath);
    } catch {
      // ignore
    }
  }
});

test("sendSocketRequest supports AbortSignal and timeouts", async () => {
  const sockPath = shortSocketPath("abort");
  try {
    fs.unlinkSync(sockPath);
  } catch {
    // ignore
  }

  const connections = new Set();
  const server = net.createServer((conn) => {
    connections.add(conn);
    conn.on("close", () => connections.delete(conn));
    // Intentionally never reply to test timeout & abort handling.
  });

  await new Promise((resolve) => server.listen(sockPath, resolve));
  try {
    const ac = new AbortController();
    setTimeout(() => ac.abort(), 30);
    await assert.rejects(
      () => sendSocketRequest(sockPath, { op: "ping" }, { timeoutMs: 2000, signal: ac.signal }),
      { name: "AbortError" },
    );

    await assert.rejects(
      () => sendSocketRequest(sockPath, { op: "ping" }, { timeoutMs: 60 }),
      /timed out after 60 ms/,
    );
  } finally {
    for (const c of connections) c.destroy();
    await new Promise((resolve) => server.close(resolve));
    try {
      fs.unlinkSync(sockPath);
    } catch {
      // ignore
    }
  }
});
