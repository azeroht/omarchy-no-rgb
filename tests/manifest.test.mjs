// Checks the plugin package itself: the manifest Omarchy reads and the files
// it points to.
import { accessSync, constants, readFileSync } from "node:fs";
import { test } from "node:test";
import assert from "node:assert/strict";

const root = new URL("../", import.meta.url);
const manifest = JSON.parse(readFileSync(new URL("manifest.json", root), "utf8"));
const SEMVER = /^\d+\.\d+\.\d+$/;

test("manifest uses schema version 1", () => {
  // ASSERT
  assert.equal(manifest.schemaVersion, 1);
});

test("manifest id matches the IPC target and the module name", () => {
  // ARRANGE
  const widget = readFileSync(new URL("BarWidget.qml", root), "utf8");

  // ASSERT
  assert.equal(manifest.id, "azeroht.no-rgb");
  assert.match(widget, /moduleName: "azeroht\.no-rgb"/);
  assert.match(widget, /target: "azeroht\.no-rgb"/);
});

test("manifest declares a bar widget whose entry point exists", () => {
  // ASSERT
  assert.deepEqual(manifest.kinds, ["bar-widget"]);
  assert.doesNotThrow(() => accessSync(new URL(manifest.entryPoints.barWidget, root)));
});

test("manifest version is semver", () => {
  // ASSERT
  assert.match(manifest.version, SEMVER);
});

test("rgb script is executable", () => {
  // ASSERT
  assert.doesNotThrow(() => accessSync(new URL("rgb.sh", root), constants.X_OK));
});
