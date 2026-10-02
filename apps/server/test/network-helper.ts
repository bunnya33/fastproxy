import net from 'node:net';

const [mode, host, portText, payload] = process.argv.slice(2);
const port = Number(portText ?? 19000);
if (mode === 'hold') {
  console.log(JSON.stringify({ ready: true, pid: process.pid }));
  setInterval(() => {}, 60_000);
} else if (mode === 'backend') {
  for (const listenPort of [port, port + 1]) {
    const tcp = net.createServer(socket => {
      console.log(JSON.stringify({ protocol: 'tcp', port: listenPort, peer: socket.remoteAddress }));
      socket.on('error', () => undefined); socket.on('data', data => socket.write(data));
    });
    await new Promise<void>(resolve => tcp.listen(listenPort, '0.0.0.0', resolve));
  }
  console.log(JSON.stringify({ ready: true, pid: process.pid }));
} else {
  const data = Buffer.from(payload ?? '', 'base64');
  const timer = setTimeout(() => { console.error('response timeout'); process.exit(2); }, 2000);
  if (mode === 'tcp-client') {
    const socket = net.createConnection({ host, port });
    const chunks: Buffer[] = [];
    socket.on('connect', () => socket.write(data));
    socket.on('data', chunk => {
      chunks.push(chunk);
      const response = Buffer.concat(chunks);
      if (response.length >= data.length) { console.log(response.toString('base64')); clearTimeout(timer); socket.destroy(); }
    });
    socket.on('error', error => { console.error(error.message); process.exit(2); });
  } else throw new Error('Unknown helper mode');
}
