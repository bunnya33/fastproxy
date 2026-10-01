import { createApp } from 'vue';
import { ElAlert, ElButton, ElConfigProvider, ElDialog, ElForm, ElFormItem, ElIcon, ElInput, ElInputNumber, ElRadioButton, ElRadioGroup, ElSwitch, ElTable, ElTableColumn } from 'element-plus';
import 'element-plus/dist/index.css';
import './style.css';
import App from './App.vue';

const app = createApp(App);
for (const component of [ElAlert, ElButton, ElConfigProvider, ElDialog, ElForm, ElFormItem, ElIcon, ElInput, ElInputNumber, ElRadioButton, ElRadioGroup, ElSwitch, ElTable, ElTableColumn]) app.use(component);
app.mount('#app');
