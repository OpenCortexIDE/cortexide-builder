'use strict';
// Pre-populates .build/builtInExtensions/<name>/ from GitHub before the gulp task runs.
// When these directories exist at the right version, getExtensionStream() in
// builtInExtensions.ts takes the fast path: vfs.src() instead of downloading+unzipping.
// This completely bypasses the gulp-vinyl-zip stream pipeline that stalls on Node 22.15.x.

const https = require('https');
const fs = require('fs');
const path = require('path');

// yauzl is already in node_modules from the VS Code npm install
const yauzlPath = path.join(process.cwd(), 'node_modules', 'yauzl');
const yauzl = require(yauzlPath);

const productJson = JSON.parse(fs.readFileSync('product.json', 'utf8'));
const builtInExtensions = productJson.builtInExtensions || [];

const GITHUB_TOKEN = process.env.GITHUB_TOKEN || '';
const headers = {
	'Authorization': `Bearer ${GITHUB_TOKEN}`,
	'User-Agent': 'CortexIDE-Builder/1.0',
};

function httpsGet(url, extraHeaders) {
	return new Promise((resolve, reject) => {
		const opts = new URL(url);
		const reqHeaders = { ...headers, ...extraHeaders, 'Host': opts.hostname };
		const req = https.get({ hostname: opts.hostname, path: opts.pathname + opts.search, headers: reqHeaders }, res => {
			if (res.statusCode === 301 || res.statusCode === 302) {
				return resolve(httpsGet(res.headers.location, extraHeaders));
			}
			const chunks = [];
			res.on('data', c => chunks.push(c));
			res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks) }));
			res.on('error', reject);
		});
		req.on('error', reject);
		req.end();
	});
}

async function getVsixAssetUrl(repoPath, version) {
	const url = `https://api.github.com/repos${repoPath}/releases/tags/v${version}`;
	const res = await httpsGet(url, { 'Accept': 'application/vnd.github+json' });
	if (res.status !== 200) throw new Error(`GitHub API returned ${res.status} for ${url}`);
	const release = JSON.parse(res.body.toString('utf8'));
	const asset = release.assets && release.assets.find(a => a.name.endsWith('.vsix'));
	if (!asset) throw new Error(`No .vsix asset found in release ${version} of ${repoPath}`);
	return asset.url;
}

async function downloadVsix(assetUrl) {
	console.log(`  Downloading: ${assetUrl}`);
	const res = await httpsGet(assetUrl, { 'Accept': 'application/octet-stream' });
	if (res.status !== 200) throw new Error(`Download failed with status ${res.status}`);
	console.log(`  Downloaded: ${res.body.length} bytes`);
	return res.body;
}

function extractVsix(buffer, destDir) {
	// Use lazyEntries: true so we control the entry reading pace (avoids race conditions)
	return new Promise((resolve, reject) => {
		yauzl.fromBuffer(buffer, { lazyEntries: true }, (err, zip) => {
			if (err) return reject(err);

			fs.mkdirSync(destDir, { recursive: true });

			zip.on('error', reject);
			zip.on('end', resolve);

			zip.on('entry', entry => {
				// Only extract files under extension/
				if (!entry.fileName.startsWith('extension/') && !entry.fileName.startsWith('extension\\')) {
					return zip.readEntry();
				}

				const relPath = entry.fileName.replace(/^extension[/\\]/, '').replace(/\\/g, path.sep);
				const destPath = path.join(destDir, relPath);

				if (entry.fileName.endsWith('/') || entry.fileName.endsWith('\\')) {
					// Directory entry
					fs.mkdirSync(destPath, { recursive: true });
					return zip.readEntry();
				}

				fs.mkdirSync(path.dirname(destPath), { recursive: true });

				zip.openReadStream(entry, (err, stream) => {
					if (err) return reject(err);
					const out = fs.createWriteStream(destPath);
					out.on('error', reject);
					out.on('finish', () => zip.readEntry());
					stream.on('error', reject);
					stream.pipe(out);
				});
			});

			zip.readEntry();
		});
	});
}

async function preloadExtension(ext) {
	const repoPath = new URL(ext.repo).pathname;
	const destDir = path.join('.build', 'builtInExtensions', ext.name);
	const pkgPath = path.join(destDir, 'package.json');

	// Check if already cached at the right version
	if (fs.existsSync(pkgPath)) {
		try {
			const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
			if (pkg.version === ext.version) {
				console.log(`[preload] ${ext.name}@${ext.version} already cached — skipping`);
				return;
			}
		} catch (_) { /* corrupt cache, re-download */ }
	}

	console.log(`[preload] Fetching ${ext.name}@${ext.version} from ${ext.repo}...`);

	const assetUrl = await getVsixAssetUrl(repoPath, ext.version);
	const vsixBuffer = await downloadVsix(assetUrl);

	fs.rmSync(destDir, { recursive: true, force: true });

	console.log(`[preload] Extracting to ${destDir}...`);
	await extractVsix(vsixBuffer, destDir);

	// Verify
	if (!fs.existsSync(pkgPath)) {
		throw new Error(`Extraction failed — ${pkgPath} not found after extract`);
	}
	console.log(`[preload] ${ext.name}@${ext.version} ready`);
}

async function main() {
	if (!GITHUB_TOKEN) {
		console.warn('[preload] Warning: GITHUB_TOKEN not set — GitHub API rate limits may apply');
	}

	console.log(`[preload] Pre-loading ${builtInExtensions.length} built-in extensions...`);

	for (const ext of builtInExtensions) {
		await preloadExtension(ext);
	}

	console.log('[preload] All built-in extensions cached. gulp-vinyl-zip will be bypassed.');
}

main().catch(err => {
	console.error('[preload] Fatal error:', err.message);
	process.exit(1);
});
