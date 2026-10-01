process.env.FASTPROXY_MODE ??= 'demo';
process.env.FASTPROXY_ADMIN_PASSWORD ??= 'FastProxy-demo-2026';
console.log('本地演示模式：不修改系统网络。用户名 admin，密码 FastProxy-demo-2026');
const { start } = await import('./main.js');
await start();
