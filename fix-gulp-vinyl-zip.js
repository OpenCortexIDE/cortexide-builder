'use strict';
// Patches node_modules/gulp-vinyl-zip/lib/src/index.js to fix a race condition
// where q.length === 0 is checked while a task is already running (dequeued from
// the queue but not yet completed). This causes toStream() to end the output stream
// prematurely under Node 22.15.x's faster event-loop scheduling.
//
// Fix: use an explicit `pending` counter that tracks tasks pushed but not yet
// completed (via callback), and a `zipEnded` flag. result.end() is called only
// when BOTH conditions are true.

const fs = require('fs');
const path = require('path');

// When called from build.sh after `cd vscode`, cwd is the cortexide source dir.
const target = path.join(process.cwd(), 'node_modules/gulp-vinyl-zip/lib/src/index.js');

if (!fs.existsSync(target)) {
  console.log('gulp-vinyl-zip not found at', target, '— skipping patch');
  process.exit(0);
}

const fixed = `'use strict';

var fs = require('fs');
var yauzl = require('yauzl');
var es = require('event-stream');
var File = require('../vinyl-zip');
var queue = require('queue');
var constants = require('constants');

function modeFromEntry(entry) {
\tvar attr = entry.externalFileAttributes >> 16 || 33188;

\treturn [448 /* S_IRWXU */, 56 /* S_IRWXG */, 7 /* S_IRWXO */]
\t\t.map(function(mask) { return attr & mask; })
\t\t.reduce(function(a, b) { return a + b; }, attr & 61440 /* S_IFMT */);
}

function mtimeFromEntry(entry) {
\treturn yauzl.dosDateTimeToDate(entry.lastModFileDate, entry.lastModFileTime);
}

function toStream(zip) {
\tvar result = es.through();
\tvar q = queue();
\tvar didErr = false;
\tvar pending = 0;   // tasks pushed but callback not yet called
\tvar zipEnded = false;

\tfunction tryEnd() {
\t\tif (zipEnded && pending === 0 && !didErr) {
\t\t\tresult.end();
\t\t}
\t}

\tq.on('error', function (err) {
\t\tdidErr = true;
\t\tresult.emit('error', err);
\t});

\tzip.on('entry', function (entry) {
\t\tif (didErr) { return; }

\t\tvar stat = new fs.Stats();
\t\tstat.mode = modeFromEntry(entry);
\t\tstat.mtime = mtimeFromEntry(entry);

\t\t// directories
\t\tif (/\\/$/.test(entry.fileName)) {
\t\t\tstat.mode = (stat.mode & ~constants.S_IFMT) | constants.S_IFDIR;
\t\t}

\t\tvar file = {
\t\t\tpath: entry.fileName,
\t\t\tstat: stat
\t\t};

\t\tif (stat.isFile()) {
\t\t\tif (entry.uncompressedSize === 0) {
\t\t\t\tfile.contents = Buffer.alloc(0);
\t\t\t\tresult.emit('data', new File(file));

\t\t\t} else {
\t\t\t\tpending++;
\t\t\t\tq.push(function (cb) {
\t\t\t\t\tzip.openReadStream(entry, function(err, readStream) {
\t\t\t\t\t\tif (err) {
\t\t\t\t\t\t\tpending--;
\t\t\t\t\t\t\ttryEnd();
\t\t\t\t\t\t\treturn cb(err);
\t\t\t\t\t\t}
\t\t\t\t\t\tfile.contents = readStream;
\t\t\t\t\t\tresult.emit('data', new File(file));
\t\t\t\t\t\tcb();
\t\t\t\t\t\tpending--;
\t\t\t\t\t\ttryEnd();
\t\t\t\t\t});
\t\t\t\t});

\t\t\t\tq.start();
\t\t\t}

\t\t} else if (stat.isSymbolicLink()) {
\t\t\tpending++;
\t\t\tq.push(function (cb) {
\t\t\t\tzip.openReadStream(entry, function(err, readStream) {
\t\t\t\t\tif (err) {
\t\t\t\t\t\tpending--;
\t\t\t\t\t\ttryEnd();
\t\t\t\t\t\treturn cb(err);
\t\t\t\t\t}
\t\t\t\t\tfile.symlink = '';
\t\t\t\t\treadStream.on('data', function(c) { file.symlink += c; });
\t\t\t\t\treadStream.on('error', function(err) {
\t\t\t\t\t\tpending--;
\t\t\t\t\t\ttryEnd();
\t\t\t\t\t\tcb(err);
\t\t\t\t\t});
\t\t\t\t\treadStream.on('end', function () {
\t\t\t\t\t\tresult.emit('data', new File(file));
\t\t\t\t\t\tcb();
\t\t\t\t\t\tpending--;
\t\t\t\t\t\ttryEnd();
\t\t\t\t\t});
\t\t\t\t});
\t\t\t});

\t\t\tq.start();

\t\t} else if (stat.isDirectory()) {
\t\t\tfile.contents = null;
\t\t\tresult.emit('data', new File(file));

\t\t} else {
\t\t\tresult.emit('data', new File(file));
\t\t}
\t});

\tzip.on('end', function() {
\t\tif (didErr) {
\t\t\treturn;
\t\t}
\t\tzipEnded = true;
\t\ttryEnd();
\t});

\treturn result;
}

function unzipBuffer(contents) {
\tvar result = es.through();
\tyauzl.fromBuffer(contents, function (err, zip) {
\t\tif (err) { return result.emit('error', err); }
\t\ttoStream(zip).pipe(result);
\t});
\treturn result;
}

function unzipFile(zipPath) {
\tvar result = es.through();
\tyauzl.open(zipPath, function (err, zip) {
\t\tif (err) { return result.emit('error', err); }
\t\ttoStream(zip).pipe(result);
\t});
\treturn result;
}

function unzip() {
\tvar input = es.through();
\tvar result = es.through();
\tvar zips = [];

\tvar output = input.pipe(es.through(function (f) {
\t\tif (!f.isBuffer()) {
\t\t\tthis.emit('error', new Error('Only supports buffers'));
\t\t}

\t\tzips.push(f);
\t}, function () {
\t\tvar streams = zips.map(function (f) {
\t\t\treturn unzipBuffer(f.contents);
\t\t});

\t\tes.merge(streams).pipe(result);
\t\tthis.emit('end');
\t}));

\treturn es.duplex(input, es.merge(output, result));
}

function src(zipPath) {
\treturn zipPath ? unzipFile(zipPath) : unzip();
}

module.exports = src;
`;

fs.writeFileSync(target, fixed, 'utf8');
console.log('Patched gulp-vinyl-zip toStream() — fixed pending-counter race condition');
