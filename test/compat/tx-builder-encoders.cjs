const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const https = require('node:https');
const { stripTypeScriptTypes, createRequire } = require('node:module');
const ethers = require('ethers');
const abiCoder = require('web3-eth-abi');
const web3Utils = require('web3-utils');

assert.equal(ethers.version, '6.17.0');
assert.equal(require('web3-eth-abi/package.json').version, '1.8.1');
assert.equal(require('web3-utils/package.json').version, '1.8.1');
const legacyRequire = createRequire(require.resolve('web3-eth-abi'));
assert.equal(legacyRequire('@ethersproject/abi/package.json').version, '5.7.0');

const profiles = [
  { repo: 'safe-global/safe-react-apps', commit: 'e8cccfb9a1042fa2954087988bae59c3b8c81780', version: '1.18.3' },
  { repo: 'safe-global/safe-wallet-monorepo', commit: '71373370acd419db94100d1351207c2f0806535d', version: '2.1.0' },
];
const get = url => new Promise((resolve, reject) => {
  https.get(url, res => {
    if (res.statusCode !== 200) { res.resume(); reject(new Error(`HTTP ${res.statusCode}: ${url}`)); return; }
    const chunks = [];
    res.on('data', chunk => chunks.push(chunk));
    res.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    res.on('error', reject);
  }).on('error', reject);
});
const compile = source => stripTypeScriptTypes(
  source.replace(/^import\b[\s\S]*?from\s+'[^']+'\s*$/gm, '').replace(/\bexport\s+/g, ''),
  { mode: 'transform' },
);

(async () => {
  const fixtures = path.join(__dirname, '../fixtures');
  const decoded = JSON.parse(fs.readFileSync(path.join(fixtures, 'tx-builder-static-vectors.json')));
  const encoded = JSON.parse(fs.readFileSync(path.join(fixtures, 'tx-builder-static-encoded.json')));
  for (const profile of profiles) {
    const base = `https://raw.githubusercontent.com/${profile.repo}/${profile.commit}/apps/tx-builder/`;
    const [manifest, fields, utils] = await Promise.all([
      get(`${base}package.json`), get(`${base}src/components/forms/fields/fields.ts`), get(`${base}src/utils.ts`),
    ]);
    assert.equal(JSON.parse(manifest).version, profile.version);
    const context = vm.createContext({ console, abiCoder, toBN: web3Utils.toBN, isAddress: ethers.isAddress,
      fromWei: web3Utils.fromWei, formatEther: ethers.formatEther, Interface: ethers.Interface });
    vm.runInContext(compile(fields) + '\n' + compile(utils), context);
    const encode = vm.runInContext('encodeToHexData', context);
    decoded.transactions.forEach((tx, index) => {
      assert.equal(encode(tx.contractMethod, tx.contractInputsValues)?.toLowerCase(), encoded.transactions[index].data.toLowerCase(),
        `${profile.version}: ${tx.contractMethod.name}`);
    });
    console.log(`Transaction Builder ${profile.version}: ${decoded.transactions.length} pinned vectors match`);
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
