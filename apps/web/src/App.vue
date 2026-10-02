<script setup lang="ts">
import { computed, onMounted, onUnmounted, reactive, ref } from 'vue';
import { ArrowRight, Connection, CopyDocument, Delete, EditPen, Fold, Lock, Plus, Refresh, Setting, Switch, SwitchButton, User, View } from '@element-plus/icons-vue';
import { ElMessage, ElMessageBox, type FormInstance, type FormRules } from 'element-plus';
import { api, RequestError, setCSRF, type Rule, type Status } from './api';
import zhCn from 'element-plus/es/locale/lang/zh-cn';

const initializing = ref(true);
const username = ref('');
const loginForm = reactive({ username: 'admin', password: '' });
const loginLoading = ref(false);
const loginError = ref('');
const status = ref<Status>();
const page = ref<'rules' | 'config' | 'system'>('rules');
const search = ref('');
const protocolFilter = ref('all');
const busy = ref(false);
const refreshing = ref(false);
const connectionError = ref('');
const dialog = ref(false);
const editing = ref(false);
const editingRevision = ref(0);
const formRef = ref<FormInstance>();
const configText = ref('');
const configRevision = ref(0);
const sidebarOpen = ref(false);
const emptyRule = (): Rule => ({ id: '', name: '', protocol: 'tcp', listen_ip: '0.0.0.0', listen_port: 8000, target_ip: '', target_port: 9000, enabled: true });
const form = reactive<Rule>(emptyRule());
const rules: FormRules = {
  name: [{ required: true, message: '请输入规则名称', trigger: 'blur' }, { max: 60, message: '最多 60 个字符', trigger: 'blur' }],
  listen_ip: [{ required: true, message: '请输入监听 IPv4 地址', trigger: 'blur' }],
  target_ip: [{ required: true, message: '请输入目标服务器 IPv4 地址', trigger: 'blur' }, { pattern: /^(?:\d{1,3}\.){3}\d{1,3}$/, message: '请输入 IPv4 地址，不支持域名', trigger: 'blur' }],
};
const allRules = computed(() => status.value?.state.rules ?? []);
const enabledRules = computed(() => allRules.value.filter(r => r.enabled).length);
const filtered = computed(() => allRules.value.filter(r => (protocolFilter.value === 'all' || r.protocol === protocolFilter.value) && `${r.name} ${r.listen_ip} ${r.listen_port} ${r.target_ip} ${r.target_port}`.toLowerCase().includes(search.value.toLowerCase())));
const totals = computed(() => Object.values(status.value?.runtime.counters ?? {}).reduce((sum, c) => ({ bytes: sum.bytes + c.bytes, connections: sum.connections + c.connections }), { bytes: 0, connections: 0 }));
const healthy = computed(() => !connectionError.value && status.value?.runtime.healthy);
const isDemo = computed(() => status.value?.runtime.mode === 'demo');
const pageTitle = computed(() => ({ rules: '转发规则', config: 'HAProxy 配置', system: '服务信息' })[page.value]);
const updatedAt = computed(() => status.value?.state.updated_at ? new Date(status.value.state.updated_at).toLocaleString('zh-CN', { hour12: false }) : '尚未修改');
function bytes(value: number): string { if (!value) return '0 B'; const i = Math.min(Math.floor(Math.log(value) / Math.log(1024)), 4); return `${(value / 1024 ** i).toFixed(i ? 1 : 0)} ${['B', 'KB', 'MB', 'GB', 'TB'][i]}`; }
function uptime(value: number): string { return value >= 86400 ? `${Math.floor(value / 86400)} 天 ${Math.floor(value % 86400 / 3600)} 小时` : value >= 3600 ? `${Math.floor(value / 3600)} 小时 ${Math.floor(value % 3600 / 60)} 分钟` : `${Math.floor(value / 60)} 分钟`; }
function failure(error: unknown): void {
  if (error instanceof RequestError && error.status === 401) { username.value = ''; status.value = undefined; setCSRF(''); }
  ElMessage.error((error as Error).message || '操作失败');
}
async function refresh(): Promise<void> {
  if (refreshing.value || busy.value || !username.value) return;
  refreshing.value = true;
  try {
    status.value = await api<Status>('/status'); connectionError.value = '';
    if (page.value === 'config' && configRevision.value !== status.value.state.revision) await loadConfig();
  }
  catch (error) {
    if (error instanceof RequestError && error.status === 401) failure(error);
    else connectionError.value = (error as Error).message || '连接服务失败';
  } finally { refreshing.value = false; }
}
async function login(): Promise<void> {
  loginError.value = ''; loginLoading.value = true;
  try {
    const session = await api<{ user: string; csrf: string }>('/login', 'POST', loginForm);
    username.value = session.user; setCSRF(session.csrf); loginForm.password = ''; await refresh();
  } catch (error) { loginError.value = (error as Error).message; }
  finally { loginLoading.value = false; }
}
async function logout(): Promise<void> {
  try { await api('/logout', 'POST', {}); username.value = ''; status.value = undefined; setCSRF(''); }
  catch (error) { failure(error); }
}
async function navigate(next: typeof page.value): Promise<void> {
  page.value = next; sidebarOpen.value = false;
  if (next === 'config') await loadConfig();
}
async function loadConfig(): Promise<void> {
  try { const result = await api<{ config: string; revision: number }>('/config'); configText.value = result.config; configRevision.value = result.revision; }
  catch (error) { failure(error); }
}
function openEditor(rule?: Rule): void {
  Object.assign(form, rule ? { ...rule, protocol: 'tcp' } : emptyRule()); editing.value = !!rule;
  editingRevision.value = status.value?.state.revision ?? 0; dialog.value = true;
  formRef.value?.clearValidate();
}
async function save(): Promise<void> {
  if (!await formRef.value?.validate().catch(() => false)) return;
  busy.value = true;
  try {
    await api(editing.value ? `/rules/${form.id}` : '/rules', editing.value ? 'PUT' : 'POST', { revision: editingRevision.value, rule: { ...form } });
    dialog.value = false; ElMessage.success(isDemo.value ? '规则已保存（演示模式）' : '规则已保存并生效');
  } catch (error) { failure(error); }
  finally { busy.value = false; await refresh(); }
}
async function toggle(rule: Rule): Promise<void> {
  busy.value = true;
  try { await api(`/rules/${rule.id}`, 'PUT', { revision: status.value!.state.revision, rule: { ...rule, enabled: !rule.enabled } }); ElMessage.success(rule.enabled ? '已停用，新连接不再匹配此规则' : '规则已启用'); }
  catch (error) { failure(error); }
  finally { busy.value = false; await refresh(); }
}
async function remove(rule: Rule): Promise<void> {
  try { await ElMessageBox.confirm(`删除「${rule.name}」？已有连接可能持续到会话超时。`, '删除规则', { confirmButtonText: '删除', cancelButtonText: '取消', type: 'warning' }); }
  catch { return; }
  busy.value = true;
  try { await api(`/rules/${rule.id}`, 'DELETE', { revision: status.value!.state.revision }); ElMessage.success('规则已删除'); }
  catch (error) { failure(error); }
  finally { busy.value = false; await refresh(); }
}
async function toggleForwarding(): Promise<void> {
  const next = !status.value!.state.forwarding;
  if (!next) {
    try { await ElMessageBox.confirm('暂停全部新连接的转发，保留已保存的规则。已有连接可能持续到会话超时。', '暂停转发', { confirmButtonText: '暂停', cancelButtonText: '取消' }); } catch { return; }
  }
  busy.value = true;
  try { await api('/forwarding', 'POST', { revision: status.value!.state.revision, forwarding: next }); ElMessage.success(next ? '已恢复转发' : '已暂停转发'); }
  catch (error) { failure(error); }
  finally { busy.value = false; await refresh(); }
}
async function reapply(): Promise<void> {
  busy.value = true;
  try { await api('/reapply', 'POST', {}); ElMessage.success('已重新应用保存的规则'); }
  catch (error) { failure(error); }
  finally { busy.value = false; await refresh(); }
}
async function copyConfig(): Promise<void> {
  try { await navigator.clipboard.writeText(configText.value); ElMessage.success('已复制配置'); }
  catch { ElMessage.info('当前浏览器无法自动复制，可选中配置文本手动复制'); }
}
let timer: ReturnType<typeof setInterval>;
onMounted(async () => {
  try { const session = await api<{ user: string; csrf: string }>('/session'); username.value = session.user; setCSRF(session.csrf); await refresh(); }
  catch (error) { if (!(error instanceof RequestError && error.status === 401)) loginError.value = '无法连接后台，请确认服务已启动'; }
  finally { initializing.value = false; }
  timer = setInterval(() => void refresh(), 5000);
});
onUnmounted(() => clearInterval(timer));
</script>

<template>
  <el-config-provider :locale="zhCn">
  <div v-if="initializing" class="boot-screen"><div class="brand-mark"><el-icon><Switch /></el-icon></div><p>正在连接 FastProxy…</p></div>
  <main v-else-if="!username" class="login-page">
    <section class="login-story">
      <a class="brand login-brand" href="/"><span class="brand-mark"><el-icon><Switch /></el-icon></span><span>FastProxy</span></a>
      <div class="story-copy"><span class="eyebrow">YOUR PORTS. YOUR ROUTES.</span><h1>让连接，<br>到达正确的地方。</h1><p>集中管理服务器端口映射。<br>一次配置，让请求与响应双向畅通。</p></div>
      <div class="route-art"><div class="art-node"><span class="node-dot"></span>请求端</div><div class="art-line"><span>TCP</span>⇄</div><div class="art-node primary"><el-icon><Connection /></el-icon>FastProxy</div><div class="art-line"><span>双向转发</span>⇄</div><div class="art-node"><span class="node-dot"></span>目标服务器</div></div>
      <div class="story-footer"><span>POWERED BY HAPROXY</span><span>TCP 转发 · 原样传递</span></div>
    </section>
    <section class="login-form-area"><div class="login-card"><span class="eyebrow">MANAGEMENT CONSOLE</span><h2>登录管理后台</h2><p class="muted">使用安装时设置的管理员账号。</p>
      <el-form label-position="top" @submit.prevent="login">
        <el-form-item label="用户名"><el-input v-model="loginForm.username" :prefix-icon="User" autocomplete="username" placeholder="admin" size="large" /></el-form-item>
        <el-form-item label="密码"><el-input v-model="loginForm.password" type="password" show-password :prefix-icon="Lock" autocomplete="current-password" placeholder="输入管理密码" size="large" /></el-form-item>
        <el-alert v-if="loginError" :title="loginError" type="error" :closable="false" show-icon />
        <el-button class="login-submit" type="primary" size="large" native-type="submit" :loading="loginLoading">进入工作台 <el-icon><ArrowRight /></el-icon></el-button>
      </el-form><p class="login-help">忘记密码？在服务器执行 <code>sudo fastproxy</code>，选择修改管理密码。</p>
    </div><span class="login-footnote">FastProxy / 端口转发管理</span></section>
  </main>
  <div v-else class="workspace">
    <aside class="sidebar" :class="{ open: sidebarOpen }">
      <a class="brand" href="/"><span class="brand-mark"><el-icon><Switch /></el-icon></span><span>FastProxy<small>NETWORK WORKSPACE</small></span></a>
      <div class="nav-label">工作台</div>
      <nav aria-label="主导航"><button :class="{ selected: page === 'rules' }" @click="navigate('rules')"><el-icon><Connection /></el-icon>转发规则<span>{{ allRules.length }}</span></button><button :class="{ selected: page === 'config' }" @click="navigate('config')"><el-icon><View /></el-icon>HAProxy 配置</button><button :class="{ selected: page === 'system' }" @click="navigate('system')"><el-icon><Setting /></el-icon>服务信息</button></nav>
      <div class="sidebar-note"><span class="mini-dot"></span><strong>双向，自动。</strong><p>请求到达目标服务器，响应沿原路径返回。</p><div class="tiny-route">CLIENT <span>⇄</span> PROXY <span>⇄</span> TARGET</div></div>
      <div class="sidebar-bottom"><div class="avatar">{{ username.slice(0, 1).toUpperCase() }}</div><div><strong>{{ username }}</strong><small>管理员</small></div><el-button text class="logout" :icon="SwitchButton" aria-label="退出登录" title="退出登录" @click="logout" /></div>
    </aside>
    <div v-if="sidebarOpen" class="sidebar-scrim" @click="sidebarOpen = false"></div>
    <div class="main-area">
      <header class="topbar"><div class="breadcrumb"><el-button class="mobile-menu" text :icon="Fold" aria-label="打开导航" @click="sidebarOpen = !sidebarOpen" /><span>工作台</span><span class="breadcrumb-slash">/</span><strong>{{ pageTitle }}</strong></div><div class="topbar-right"><span class="live-indicator" :class="{ bad: !healthy }"><i></i>{{ connectionError ? '连接中断' : healthy ? (isDemo ? '演示模式' : 'HAProxy 就绪') : 'HAProxy 异常' }}</span><span class="revision">r{{ status?.state.revision ?? 0 }}</span></div></header>
      <main class="content">
        <el-alert v-if="isDemo" class="page-alert" type="warning" title="本地演示模式：规则可保存和预览，不会修改系统网络，也不会实际转发流量。" :closable="false" show-icon />
        <el-alert v-if="connectionError || status?.runtime.error" class="page-alert" type="error" :title="connectionError || status?.runtime.error" :closable="false" show-icon />
        <el-alert v-if="allRules.some(r => r.protocol === 'udp')" class="page-alert" type="warning" title="旧 UDP 规则已保留但停用。HAProxy 不支持通用 UDP 转发，可以修改为 TCP 或删除。" :closable="false" show-icon />
        <template v-if="page === 'rules'">
          <div class="page-heading"><div><span class="eyebrow">PORT FORWARDING</span><h1>转发规则<span class="title-dot">.</span></h1><p class="muted">将本机端口连接到目标服务器，保存即生效。</p></div><el-button type="primary" size="large" :icon="Plus" :disabled="busy || !status || !!connectionError" @click="openEditor()">新建规则</el-button></div>
          <section class="metrics"><article><span class="metric-label">转发状态</span><div class="metric-value status-value"><span class="metric-dot" :class="{ paused: !status?.state.forwarding || !healthy }"></span>{{ !healthy ? '待检查' : status?.state.forwarding ? '运行中' : '已暂停' }}</div><span class="metric-detail">{{ isDemo ? 'DEMO / 无实际转发' : 'HAPROXY / TCP' }}</span></article><article><span class="metric-label">已启用规则</span><div class="metric-value">{{ enabledRules }}<small>/ {{ allRules.length }}</small></div><span class="metric-detail">{{ status?.state.forwarding ? 'TCP 双向转发' : '全局已暂停，规则保持保存' }}</span></article><article><span class="metric-label">本轮双向流量</span><div class="metric-value">{{ bytes(totals.bytes) }}</div><span class="metric-detail">发布规则或重启后重新计数</span></article><article><span class="metric-label">累计连接</span><div class="metric-value">{{ totals.connections.toLocaleString() }}</div><span class="metric-detail">每 5 秒从 HAProxy 刷新</span></article></section>
          <section class="rules-card"><div class="rules-toolbar"><div class="filter-tabs"><button v-for="item in [{ value: 'all', label: '全部规则' }, { value: 'tcp', label: 'TCP' }, { value: 'udp', label: '旧 UDP（已停用）' }]" :key="item.value" :class="{ active: protocolFilter === item.value }" @click="protocolFilter = item.value">{{ item.label }}</button></div><div class="table-tools"><el-input v-model="search" clearable placeholder="搜索名称、IP 或端口" :prefix-icon="View" /><el-button :icon="Refresh" :loading="refreshing" aria-label="刷新状态" title="刷新状态" @click="refresh" /></div></div>
            <el-table :data="filtered" row-key="id" class="rules-table" :empty-text="allRules.length ? '没有匹配的规则' : '暂无规则'">
              <el-table-column label="规则名称" min-width="170"><template #default="{ row }"><div class="rule-name"><span class="rule-symbol"><el-icon><Connection /></el-icon></span><div><strong>{{ row.name }}</strong><small>{{ row.protocol === 'udp' ? 'UDP（不支持）' : 'TCP' }} 转发</small></div></div></template></el-table-column>
              <el-table-column label="本机监听" min-width="160"><template #default="{ row }"><div class="endpoint"><strong>:{{ row.listen_port }}</strong><small>{{ row.listen_ip === '0.0.0.0' ? '全部本机 IPv4' : row.listen_ip }}</small></div></template></el-table-column>
              <el-table-column width="40"><template #default><span class="route-arrow">→</span></template></el-table-column>
              <el-table-column label="目标服务器" min-width="185"><template #default="{ row }"><div class="endpoint"><strong>{{ row.target_ip }}<span>:{{ row.target_port }}</span></strong><small>双向传递数据</small></div></template></el-table-column>
              <el-table-column label="状态" width="110"><template #default="{ row }"><el-switch :model-value="row.enabled" :disabled="busy || !!connectionError || row.protocol === 'udp'" :aria-label="`启停规则 ${row.name}`" @change="toggle(row)" /><span class="switch-label">{{ row.enabled ? '开启' : '停用' }}</span></template></el-table-column>
              <el-table-column label="双向流量" width="110"><template #default="{ row }"><span class="mono muted">{{ bytes(status?.runtime.counters[row.id]?.bytes ?? 0) }}</span></template></el-table-column>
              <el-table-column label="操作" width="112" fixed="right"><template #default="{ row }"><el-button text :icon="EditPen" :disabled="busy || !!connectionError" :aria-label="`编辑 ${row.name}`" title="编辑规则" @click="openEditor(row)" /><el-button text :icon="Delete" :disabled="busy || !!connectionError" :aria-label="`删除 ${row.name}`" title="删除规则" @click="remove(row)" /></template></el-table-column>
              <template #empty><div v-if="!allRules.length" class="empty-rules"><span class="empty-icon"><el-icon><Connection /></el-icon></span><h3>创建你的第一条连接</h3><p>选择本机端口，填写目标服务器地址与端口。<br>请求与响应会自动双向转发。</p><el-button type="primary" plain :icon="Plus" :disabled="!status || !!connectionError" @click="openEditor()">新建转发规则</el-button></div><div v-else class="search-empty">没有匹配的规则，请调整搜索条件。</div></template>
            </el-table><div class="table-footer"><span>{{ filtered.length }} 条规则 · 最近更新 {{ updatedAt }}</span><span class="saved-mark"><i></i>平滑重载 · 持久保存</span></div>
          </section>
          <section class="bottom-grid"><article class="flow-card"><div><span class="eyebrow">HOW IT WORKS</span><h3>一条规则，完整往返。</h3></div><div class="flow-diagram"><span>请求端</span><b>⇄</b><span class="flow-middle">本机端口</span><b>⇄</b><span>目标端口</span></div><p>应用数据保持不变，目标通常看到转发服务器的 IP。请放行安全组和本机防火墙中的监听端口。</p></article><article class="control-card"><span class="eyebrow">GLOBAL CONTROL</span><h3>{{ status?.state.forwarding ? '所有连接，各就其位。' : '转发已暂停。' }}</h3><p>规则变更影响新连接，已有会话可能持续到超时。</p><el-button :icon="SwitchButton" :disabled="busy || !status || !!connectionError" @click="toggleForwarding">{{ status?.state.forwarding ? '暂停全部转发' : '恢复全部转发' }}</el-button></article></section>
        </template>
        <template v-else-if="page === 'config'"><div class="page-heading"><div><span class="eyebrow">HAPROXY CONFIGURATION</span><h1>HAProxy 配置<span class="title-dot">.</span></h1><p class="muted">根据已保存规则生成的 HAProxy TCP 配置，保存后校验并平滑重载。</p></div><el-button :icon="Refresh" @click="loadConfig">刷新配置</el-button></div><section class="code-card"><div class="code-toolbar"><span><i></i>haproxy.cfg <small>r{{ configRevision }}</small></span><el-button text :icon="CopyDocument" @click="copyConfig">复制</el-button></div><pre>{{ configText }}</pre></section><el-alert class="page-alert config-note" type="info" :closable="false" title="配置用于查看和排查。修改规则请回到转发规则页面，避免手动编辑与保存状态不一致。" show-icon /></template>
        <template v-else><div class="page-heading"><div><span class="eyebrow">SERVICE INFORMATION</span><h1>服务信息<span class="title-dot">.</span></h1><p class="muted">了解运行状态，在服务器终端管理服务。</p></div><el-button :icon="Refresh" :loading="refreshing" @click="refresh">刷新状态</el-button></div><div class="system-grid"><section class="info-card"><h3>当前状态</h3><dl><dt>转发引擎</dt><dd>{{ isDemo ? '本地演示' : 'HAProxy TCP' }}</dd><dt>HAProxy 状态</dt><dd>{{ healthy ? '就绪' : '需要检查' }}</dd><dt>HAProxy 版本</dt><dd>{{ status?.runtime.version ?? (isDemo ? '演示模式' : '未知') }}</dd><dt>等待旧连接结束</dt><dd>{{ status?.runtime.draining_workers ?? 0 }} 个进程</dd><dt>运行时长</dt><dd>{{ uptime(status?.uptime_seconds ?? 0) }}</dd><dt>受保护端口</dt><dd class="mono">{{ status?.protected_ports.join(', ') }}</dd><dt>配置版本</dt><dd class="mono">r{{ status?.state.revision }}</dd><dt>最近修改</dt><dd>{{ updatedAt }}</dd></dl><el-button :icon="Refresh" :disabled="busy" @click="reapply">重新应用保存的规则</el-button></section><section class="info-card terminal-card"><h3>在终端管理</h3><p class="muted">数字菜单与网页后台共享配置。</p><div class="terminal-block"><span>$</span> sudo fastproxy</div><div class="command-row"><span>查看状态</span><code>sudo fastproxy status</code></div><div class="command-row"><span>重启服务</span><code>sudo fastproxy restart</code></div><div class="command-row"><span>停止服务</span><code>sudo fastproxy stop</code></div><div class="command-row"><span>查看日志</span><code>sudo fastproxy logs</code></div><p class="terminal-note">管理地址和密码也可通过数字菜单修改。停止服务会关闭监听并结束连接；再次启动后恢复已保存规则。</p></section></div></template>
        <footer class="page-footer"><span>FastProxy</span><span>简单配置，稳定连接。</span></footer>
      </main>
    </div>
    <el-dialog v-model="dialog" :title="editing ? '修改转发规则' : '新建转发规则'" width="570px" class="rule-dialog" :close-on-click-modal="false" :close-on-press-escape="!busy" :show-close="!busy" @closed="formRef?.clearValidate()">
      <p class="dialog-intro">设置本机入口与目标地址，保存后立即应用。</p><el-form ref="formRef" :model="form" :rules="rules" label-position="top" :disabled="busy" @submit.prevent="save">
        <el-form-item label="规则名称" prop="name"><el-input v-model="form.name" placeholder="例如：生产数据库、游戏服务器" maxlength="60" /></el-form-item>
        <el-form-item label="转发协议"><span class="field-help">HAProxy 社区版仅支持通用 TCP 转发。</span><el-radio-group v-model="form.protocol"><el-radio-button value="tcp">TCP</el-radio-button></el-radio-group></el-form-item>
        <div class="endpoint-fields"><el-form-item label="本机监听 IPv4" prop="listen_ip"><el-input v-model="form.listen_ip" placeholder="0.0.0.0" /><span class="field-help">0.0.0.0 表示全部本机地址</span></el-form-item><el-form-item label="监听端口"><el-input-number v-model="form.listen_port" :min="1" :max="65535" :precision="0" controls-position="right" /></el-form-item></div>
        <div class="form-route-divider"><span></span><el-icon><ArrowRight /></el-icon><small>原样转发，自动回包</small><span></span></div>
        <div class="endpoint-fields"><el-form-item label="目标服务器 IPv4" prop="target_ip"><el-input v-model="form.target_ip" placeholder="例如 10.0.0.20" /></el-form-item><el-form-item label="目标端口"><el-input-number v-model="form.target_port" :min="1" :max="65535" :precision="0" controls-position="right" /></el-form-item></div>
        <el-form-item label="启用规则"><el-switch v-model="form.enabled" /><span class="field-help inline">{{ form.enabled ? '保存后参与转发' : '保存规则，暂不参与转发' }}</span></el-form-item>
      </el-form><template #footer><el-button :disabled="busy" @click="dialog = false">取消</el-button><el-button type="primary" :loading="busy" @click="save">{{ isDemo ? '保存演示规则' : '保存并生效' }}</el-button></template>
    </el-dialog>
  </div>
  </el-config-provider>
</template>
