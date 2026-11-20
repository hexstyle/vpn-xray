// Execute the complete production chunk; API/DOM are controlled leaves.
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const elements = new Map();
const element = id => {
  if (!elements.has(id)) elements.set(id, {style: {}, value: '', dataset: {}, addEventListener() {}});
  return elements.get(id);
};
const noop = () => {};
const calls = [];
const context = {
  document: {getElementById: element, querySelectorAll: () => []},
  state: {}, vpsApi: 'vps', runtimeApi: 'runtime',
  setInterval: () => 1, clearInterval: noop, sleep: async () => {},
  formPayload: () => ({profile_id: 'default'}), escapeHtml: String,
  refreshAll: async () => {}, refreshRules: async () => {},
  callApi: async (api, action, payload) => {
    if (action === 'status') return {};
    calls.push({action, payload});
    if (action === 'diagnose_repair' && calls.length === 1) throw new Error('scheduling response lost');
    if (action === 'diagnose_repair') return {ok: true, rejoined: true, job_id: '1-1', job_state: 'running'};
    assert.equal(action, 'diagnose_repair_status');
    return {ok: false, applied: true, router_apply: 'applied', path_health: 'failed',
      steps: [{id: 'selected_path', status: 'failed', message: 'incomplete HTTP200'}],
      raw_log: 'curl_exit=28 http=200 bytes=5456'};
  },
};
for (const name of ['beginForegroundTask','endForegroundTask','setBusy','flash','clearDirty','renderAll',
  'loadLogs','loadHealth','runSmoke','closeScriptEditor','saveExternalScript','revertScriptEditor',
  'updateScriptEditorDirtyState','hideRulesTextModal','markDirty','markRulesDirty','markRulesConfigDirty',
  'updateRulesConfigUi','setStartupControlsDisabled','flashLoading','renderRulesModeUi','refreshRulesMode','clearFlash']) {
  context[name] = noop;
}
vm.createContext(context);
vm.runInContext(fs.readFileSync('routers/common/files/xray-app-6.js', 'utf8'), context);
(async () => {
  element('repairCredsForm').style.display = '';
  element('repairSshPassword').value = 'synthetic-one-shot';
  await context.runDiagnoseRepairOnce(element('diagnoseRepairBtn'), {ssh_password: 'synthetic-one-shot'});
  assert.equal(calls.length, 3);
  assert.equal(calls[0].payload.request_id, calls[1].payload.request_id);
  assert.equal(calls[2].payload.job_id, '1-1');
  assert.equal(element('repairCredsForm').style.display, 'none');
  assert.equal(element('repairSshPassword').value, '');
  assert.match(element('profileActionHint').textContent, /applied.*failed/);
  assert.equal(context.state.repairRunning, false);
  console.log('PASS: lost reply rejoined; applied/unhealthy clears credential form and password');
  calls.length = 0;
  context.activeProfile = () => ({id: 'default'});
  context.window = {confirm: () => true};
  context.callApi = async (api, action, payload) => {
    calls.push({action, payload});
    if (action === 'apply_router') return {ok: true, job_id: '123-456'};
    assert.equal(action, 'apply_router_status');
    assert.equal(payload.job_id, '123-456', 'Apply polled the current job instead of its accepted generation');
    return {job: {state: 'done', router_apply: 'applied', path_health: 'ok'}};
  };
  vm.runInContext(fs.readFileSync('routers/common/files/xray-app-7.js', 'utf8'), context);
  await context.applyRouterProfile(element('applyRouterProfileBtn'));
  assert.equal(calls.length, 2);
  assert.equal(calls[1].payload.job_id, '123-456');
  console.log('PASS: complete Apply UI polls its accepted job ID');
  // Optional real worker/status results from the controlled SSH error matrix.
  for (const resultFile of process.argv.slice(2)) {
    for (const data of JSON.parse(fs.readFileSync(resultFile, 'utf8'))) {
      const flashes = [];
      context.flash = message => flashes.push(message);
      context.callApi = async (api, action, payload) => {
        if (action === 'diagnose_repair') return {ok: true, job_id: '1-1'};
        assert.equal(action, 'diagnose_repair_status');
        assert.equal(payload.job_id, '1-1');
        return data;
      };
      await context.runDiagnoseRepairOnce(element('diagnoseRepairBtn'));
      assert.equal(context.state.repairRunning, false);
      assert.equal(element('repairCredsForm').style.display, data.error === 'credentials_required' ? '' : 'none');
      assert.equal(element('repairRawLog').textContent, data.raw_log);
      if (data.error === 'credentials_required') {
        assert.match(element('profileActionHint').textContent, /one-time password/);
      } else {
        assert(flashes.some(message => message.includes('Repair finished with issues')));
      }
      assert(!flashes.some(message => message.includes('result unavailable')));
    }
    console.log('PASS: actual worker/status error bodies reach complete UI terminal/report');
  }
})().catch(err => { console.error(err); process.exitCode = 1; });
