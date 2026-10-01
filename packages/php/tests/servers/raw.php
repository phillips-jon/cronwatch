<?php

// A server on a raw socket, for the tests of NativeHttp's own HTTP client,
// where php -S cannot misbehave the way they need. It prints "ready <port>",
// answers one request as the mode says, then prints what it did and exits:
//   trickle         the status line, then one header line every 100 ms, 40
//                   of them; prints "sent <n>", the lines written before the
//                   client hung up
//   chunked         200 with "hello world" in two chunks, and the connection
//                   left open after the last one
//   chunkline       200 chunked, then a chunk-size line that never ends, as
//                   fast as it is read, for at most 8 seconds; prints "sent <n>"
//   continue        "100 Continue" blocks, one after another, the same way
//   tls <cert>      over TLS with that certificate and key: 201 "ok"
//
//     php raw.php trickle|chunked|chunkline|continue|tls [cert.pem]

declare(strict_types=1);

$mode = $argv[1] ?? '';
$context = stream_context_create($mode === 'tls' ? ['ssl' => ['local_cert' => $argv[2], 'verify_peer' => false]] : []);
$server = stream_socket_server(($mode === 'tls' ? 'tls' : 'tcp') . '://127.0.0.1:0', $errno, $error, STREAM_SERVER_BIND | STREAM_SERVER_LISTEN, $context);
if ($server === false) {
    fwrite(STDERR, "{$error}\n");
    exit(1);
}
$name = (string) stream_socket_get_name($server, false);
echo 'ready ' . substr($name, strrpos($name, ':') + 1) . "\n";
flush();
$client = @stream_socket_accept($server, 30);
if ($client === false) {
    exit(1);
}
$request = '';
while (!str_contains($request, "\r\n\r\n")) {
    $chunk = fread($client, 8192);
    if ($chunk === false || $chunk === '') {
        exit(1);
    }
    $request .= $chunk;
}
if (preg_match('/content-length: *([0-9]+)/i', $request, $m) === 1) {
    $body = substr($request, strpos($request, "\r\n\r\n") + 4);
    while (strlen($body) < (int) $m[1]) {
        $chunk = fread($client, 8192);
        if ($chunk === false || $chunk === '') {
            break;
        }
        $body .= $chunk;
    }
}
if ($mode === 'trickle') {
    stream_set_blocking($client, true);
    @fwrite($client, "HTTP/1.1 200 OK\r\n");
    $sent = 0;
    for ($i = 0; $i < 40; $i++) {
        usleep(100_000);
        if (@fwrite($client, "X-Slow-{$i}: y\r\n") === false || feof($client)) {
            break;
        }
        $sent++;
    }
    @fwrite($client, "Content-Length: 2\r\n\r\nok");
    echo "sent {$sent}\n";
} elseif ($mode === 'chunked') {
    fwrite($client, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n");
    // Left open: the client ends at the last chunk, not at the end of the stream.
    fread($client, 1);
    echo "done\n";
} elseif ($mode === 'chunkline' || $mode === 'continue') {
    // As fast as the client reads, for at most 8 seconds: a chunk-size line
    // that never ends, or one "100 Continue" after another.
    stream_set_blocking($client, true);
    $piece = $mode === 'chunkline' ? str_repeat('f', 65536) : str_repeat("HTTP/1.1 100 Continue\r\n\r\n", 2048);
    @fwrite($client, $mode === 'chunkline' ? "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" : '');
    $until = microtime(true) + 8;
    $sent = 0;
    while (microtime(true) < $until) {
        $n = @fwrite($client, $piece);
        if ($n === false || $n === 0 || feof($client)) {
            break;
        }
        $sent += $n;
    }
    echo "sent {$sent}\n";
} elseif ($mode === 'tls') {
    fwrite($client, "HTTP/1.1 201 Created\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
    echo "done\n";
}
fclose($client);
