// Checks the components panel: names and labels come from OpenRGB, external
// data that must never be read as rich text.
import { readFileSync } from "node:fs";
import { test } from "node:test";
import assert from "node:assert/strict";

const panel = readFileSync(new URL("../ComponentsPanel.qml", import.meta.url), "utf8");
const TEXT_BLOCK_START = "Text {";
const PLAIN_TEXT = "textFormat: Text.PlainText";
const MODEL_DATA = "row.modelData";

function textBlocks(source) {
  return source.split(TEXT_BLOCK_START).slice(1).map((block) => block.split("}")[0]);
}

function showsModelData(block) {
  return block.includes(MODEL_DATA);
}

test("every text showing OpenRGB data is plain text", () => {
  // ARRANGE
  const blocks = textBlocks(panel).filter(showsModelData);

  // ASSERT
  assert.notEqual(blocks.length, 0);
  for (const block of blocks) assert.ok(block.includes(PLAIN_TEXT), block);
});
