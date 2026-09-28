<?php

// A router for `php -S`, standing in for a provider in ChannelsTest: it
// appends each request (method, path, headers, body) to the file named by
// CW_LOG as a JSON line, then answers as the path says:
//   /status/<code>          that status, empty body
//   /redirect?to=<url>      307 to that URL
//   /drip                   500 with a 30 byte body sent one byte every 200 ms
//   /hang                   nothing for 5 seconds, then 200

declare(strict_types=1);

$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH) ?: '/';
$headers = [];
foreach (getallheaders() as $name => $value) {
    $headers[strtolower($name)] = $value;
}
file_put_contents((string) getenv('CW_LOG'), json_encode([
    'method' => $_SERVER['REQUEST_METHOD'],
    'uri' => $_SERVER['REQUEST_URI'],
    'headers' => $headers,
    'body' => file_get_contents('php://input'),
]) . "\n", FILE_APPEND | LOCK_EX);

if (preg_match('#^/status/([0-9]{3})$#', $path, $m) === 1) {
    http_response_code((int) $m[1]);
    return true;
}
if ($path === '/redirect') {
    header('Location: ' . ($_GET['to'] ?? '/'), true, 307);
    return true;
}
if ($path === '/drip') {
    http_response_code(500);
    header('Content-Length: 30');
    while (ob_get_level() > 0) {
        ob_end_flush();
    }
    for ($i = 0; $i < 30; $i++) {
        echo 'x';
        flush();
        usleep(200_000);
    }
    return true;
}
if ($path === '/hang') {
    sleep(5);
    return true;
}
http_response_code(404);
return true;
