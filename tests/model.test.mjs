// Unit tests for Model.js, the pure logic behind the bar widget.
// Model.js is a QML JavaScript library: its ".pragma library" header is
// dropped and the file runs in a sandbox that exposes its top-level names.
import { readFileSync } from "node:fs";
import { test } from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";

const MODEL_PATH = new URL("../Model.js", import.meta.url);
const SCRIPT_PATH = "/plugins/azeroht.no-rgb/rgb.sh";

function loadModel() {
  const source = readFileSync(MODEL_PATH, "utf8").replace(/^\.pragma library\s*$/m, "");
  const context = { console: { warn: () => {} } };
  vm.createContext(context);
  vm.runInContext(source, context);
  return context;
}

// Values built inside the sandbox come from another realm: a JSON round trip
// makes them comparable with deepEqual.
function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

const Model = loadModel();

test("defaults: lights off, nothing excluded", () => {
  // ASSERT
  assert.deepEqual(plain(Model.DEFAULTS), { enabled: false, off: [] });
});

test.describe("parse", () => {
  for (const [label, text] of [
    ["invalid JSON", "{"],
    ["null", "null"],
    ["an empty string", ""],
  ]) {
    test(`returns an empty object for ${label}`, () => {
      // ASSERT
      assert.deepEqual(plain(Model.parse(text)), {});
    });
  }
});

test.describe("normalize", () => {
  test("keeps a valid state", () => {
    // ACT
    const state = Model.normalize({ enabled: true, off: ["ENE DRAM"] });

    // ASSERT
    assert.deepEqual(plain(state), { enabled: true, off: ["ENE DRAM"] });
  });

  test("only true turns the lights on", () => {
    // ASSERT
    assert.equal(Model.normalize({ enabled: "yes" }).enabled, false);
  });

  test("drops excluded names that are not strings", () => {
    // ASSERT
    assert.deepEqual(plain(Model.normalize({ off: ["GPU", 3, null] }).off), ["GPU"]);
  });

  test("ignores an excluded list that is not an array", () => {
    // ASSERT
    assert.deepEqual(plain(Model.normalize({ off: "GPU" }).off), []);
  });

  test("falls back to the defaults for nothing", () => {
    // ASSERT
    assert.deepEqual(plain(Model.normalize(undefined)), { enabled: false, off: [] });
  });
});

test.describe("describe", () => {
  test("on", () => {
    // ASSERT
    assert.equal(Model.describe({ enabled: true, off: [] }), "on");
  });

  test("off", () => {
    // ASSERT
    assert.equal(Model.describe({ enabled: false, off: [] }), "off");
  });
});

test.describe("isComponentEnabled", () => {
  test("an excluded component is disabled", () => {
    // ASSERT
    assert.equal(Model.isComponentEnabled({ enabled: true, off: ["GPU"] }, "GPU"), false);
  });

  test("any other component is enabled", () => {
    // ASSERT
    assert.equal(Model.isComponentEnabled({ enabled: true, off: ["GPU"] }, "ENE DRAM"), true);
  });
});

test.describe("parseComponents", () => {
  test("labels components by their type", () => {
    // ARRANGE
    const text = JSON.stringify([
      { name: "ENE DRAM", type: "DRAM" },
      { name: "RTX", type: "GPU" },
      { name: "Strip" },
    ]);

    // ACT
    const components = Model.parseComponents(text);

    // ASSERT
    assert.deepEqual(plain(components), [
      { name: "ENE DRAM", label: "RAM", isMissing: false },
      { name: "RTX", label: "GPU", isMissing: false },
      { name: "Strip", label: "Strip", isMissing: false },
    ]);
  });

  test("skips invalid entries", () => {
    // ARRANGE
    const text = JSON.stringify([null, 3, { name: "" }, { type: "GPU" }]);

    // ASSERT
    assert.equal(Model.parseComponents(text).length, 0);
  });

  test("returns nothing for a list that is not an array", () => {
    // ASSERT
    assert.equal(Model.parseComponents("{}").length, 0);
  });
});

test.describe("withMissing", () => {
  test("adds the excluded components that are no longer detected", () => {
    // ARRANGE
    const components = [{ name: "A", label: "RAM", isMissing: false }];

    // ACT
    const rows = Model.withMissing(components, { enabled: true, off: ["A", "B"] });

    // ASSERT
    assert.deepEqual(plain(rows), [
      { name: "A", label: "RAM", isMissing: false },
      { name: "B", label: "B", isMissing: true },
    ]);
  });

  test("adds nothing when nothing is excluded", () => {
    // ASSERT
    assert.equal(Model.withMissing([], { enabled: true, off: [] }).length, 0);
  });
});

test.describe("command", () => {
  test("global action", () => {
    // ASSERT
    assert.deepEqual(plain(Model.command(SCRIPT_PATH, "toggle")), [SCRIPT_PATH, "toggle"]);
  });

  test("component action, as separate arguments", () => {
    // ACT
    const command = Model.command(SCRIPT_PATH, "component", "ENE DRAM", "off");

    // ASSERT
    assert.deepEqual(plain(command), [SCRIPT_PATH, "component", "ENE DRAM", "off"]);
  });

  test("a name with shell characters stays one argument", () => {
    // ACT
    const command = Model.command(SCRIPT_PATH, "component", "x; rm -rf ~", "off");

    // ASSERT
    assert.equal(command.length, 4);
    assert.equal(command[2], "x; rm -rf ~");
  });
});
