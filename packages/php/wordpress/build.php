<?php

/**
 * Builds the plugin zip the WordPress.org directory takes:
 *
 *     php wordpress/build.php [output directory]      (from packages/php)
 *
 * writes cronwatch-<version>.zip (default into wordpress/dist/) holding one
 * folder, cronwatch/: the plugin's own files (cronwatch.php, uninstall.php,
 * readme.txt, includes/) and the library it runs on (lib/src, with its MIT
 * LICENSE as lib/LICENSE). Nothing else goes in: no tests, no Composer
 * files, no build script, no dotfiles. The version is the library's
 * (Cronwatch::VERSION); the plugin header's Version and the readme's Stable
 * tag must match it, and the build stops when they do not. Entries carry a
 * fixed time, so the same sources give the same zip.
 */

declare(strict_types=1);

$plugin = __DIR__;
$library = dirname(__DIR__);
$out = $argv[1] ?? "{$plugin}/dist";

if (!class_exists(ZipArchive::class)) {
    fwrite(STDERR, "build: needs the zip extension\n");
    exit(1);
}

$version = preg_match("/public const VERSION = '([^']+)'/", (string) file_get_contents("{$library}/src/Cronwatch.php"), $m) === 1 ? $m[1] : null;
$header = preg_match('/^ \* Version:\s+(\S+)$/m', (string) file_get_contents("{$plugin}/cronwatch.php"), $m) === 1 ? $m[1] : null;
$stable = preg_match('/^Stable tag:\s+(\S+)$/m', (string) file_get_contents("{$plugin}/readme.txt"), $m) === 1 ? $m[1] : null;
if ($version === null || $header !== $version || $stable !== $version) {
    fwrite(STDERR, 'build: versions differ: library ' . var_export($version, true) . ', cronwatch.php ' . var_export($header, true) . ', readme.txt ' . var_export($stable, true) . "\n");
    exit(1);
}

/** Every file under a directory, relative to it, sorted, dotfiles left out. */
function cronwatch_build_files(string $dir): array
{
    $files = [];
    $items = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS));
    foreach ($items as $item) {
        $relative = substr($item->getPathname(), strlen($dir) + 1);
        if ($item->isFile() && !preg_match('#(^|/)\.#', $relative)) {
            $files[] = str_replace(DIRECTORY_SEPARATOR, '/', $relative);
        }
    }
    sort($files);
    return $files;
}

$entries = [];
foreach (['cronwatch.php', 'uninstall.php', 'readme.txt'] as $file) {
    $entries["cronwatch/{$file}"] = "{$plugin}/{$file}";
}
foreach (cronwatch_build_files("{$plugin}/includes") as $file) {
    $entries["cronwatch/includes/{$file}"] = "{$plugin}/includes/{$file}";
}
foreach (cronwatch_build_files("{$library}/src") as $file) {
    $entries["cronwatch/lib/src/{$file}"] = "{$library}/src/{$file}";
}
$entries['cronwatch/lib/LICENSE'] = "{$library}/LICENSE";

if (!is_dir($out) && !mkdir($out, 0777, true) && !is_dir($out)) {
    fwrite(STDERR, "build: cannot create {$out}\n");
    exit(1);
}
$zipPath = rtrim($out, '/') . "/cronwatch-{$version}.zip";
@unlink($zipPath);
$zip = new ZipArchive();
if ($zip->open($zipPath, ZipArchive::CREATE | ZipArchive::EXCL) !== true) {
    fwrite(STDERR, "build: cannot write {$zipPath}\n");
    exit(1);
}
// 2026-01-01 00:00:00 UTC, so the zip does not change with the checkout's file times.
$time = 1767225600;
foreach ($entries as $name => $source) {
    $zip->addFile($source, $name);
    $zip->setMtimeName($name, $time);
    $zip->setExternalAttributesName($name, ZipArchive::OPSYS_UNIX, 0644 << 16);
}
$zip->close();
echo "wrote {$zipPath} (" . count($entries) . " files)\n";
