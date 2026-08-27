"use strict";

const path = require("node:path");

const BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

function encodeVlq(value) {
  let unsigned = value < 0 ? ((-value) << 1) | 1 : value << 1;
  let encoded = "";
  do {
    let digit = unsigned & 31;
    unsigned >>>= 5;
    if (unsigned > 0) digit |= 32;
    encoded += BASE64[digit];
  } while (unsigned > 0);
  return encoded;
}

function identityLineMappings(originalLineCount, generatedLineCount) {
  const lines = [];
  for (let line = 0; line < generatedLineCount; line += 1) {
    lines.push(line < originalLineCount
      ? `${encodeVlq(0)}${encodeVlq(0)}${encodeVlq(line === 0 ? 0 : 1)}${encodeVlq(0)}`
      : "");
  }
  return lines.join(";");
}

function splitSourceMapReference(source, assetName) {
  const match = source.match(/(?:\r?\n)?\/\/# sourceMappingURL=([^\s]+)\s*$/u);
  const body = match ? source.slice(0, match.index) : source;
  const reference = match?.[1] ?? `${assetName}.map`;
  return {
    body,
    mapName: path.basename(reference),
  };
}

function withSourceMap({ assetName, originalSource, patchedSource }) {
  const original = splitSourceMapReference(originalSource, assetName);
  const patched = splitSourceMapReference(patchedSource, assetName);
  const originalLineCount = original.body.split(/\r?\n/u).length;
  const generatedLineCount = patched.body.split(/\r?\n/u).length;
  const mapName = original.mapName || patched.mapName;
  const map = {
    version: 3,
    file: assetName,
    sources: [assetName],
    names: [],
    mappings: identityLineMappings(originalLineCount, generatedLineCount),
  };
  return {
    source: `${patched.body}\n//# sourceMappingURL=${mapName}\n`,
    mapName,
    mapText: `${JSON.stringify(map)}\n`,
  };
}

module.exports = { withSourceMap };
