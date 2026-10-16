/* CarbonBoo Web 后台管理端脚本（唯一 JS 文件；原生 fetch，无框架、无构建链）。
 *
 * 三条原则
 * --------
 * 1. **服务端渲染优先**：页面上的数据都是 Jinja2 渲出来的；本脚本只负责"把用户的修改发出去"，
 *    成功后 `location.reload()` 让页面重新从服务端取真值。不做局部 DOM 状态、不缓存数据。
 * 2. **同一个路径既是页面又是接口**：所有请求显式带 `Accept: application/json`，
 *    加上 Cookie 会话（same-origin），因此一定要 `credentials: 'same-origin'`。
 * 3. **失败必须说人话**：统一信封 `{ok:false, code, message}` 的 message 直接展示。
 */
(function () {
  'use strict';

  function flash(message, isError) {
    var box = document.getElementById('flash');
    if (!box) { window.alert(message); return; }
    box.textContent = message;
    box.classList.toggle('is-error', !!isError);
    box.hidden = false;
    if (!isError) { window.setTimeout(function () { box.hidden = true; }, 4000); }
    window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  function api(path, options) {
    var init = options || {};
    init.headers = Object.assign({
      'Accept': 'application/json',
      'X-Requested-With': 'carbonboo-admin'
    }, init.headers || {});
    init.credentials = 'same-origin';
    return fetch(path, init).then(function (response) {
      return response.json().catch(function () {
        return { ok: false, code: 'SERVER_ERROR', message: '服务端返回了非 JSON 响应（HTTP ' + response.status + '）' };
      }).then(function (body) {
        if (!response.ok || body.ok === false) {
          var error = new Error(body.message || ('请求失败（HTTP ' + response.status + '）'));
          error.code = body.code;
          error.status = response.status;
          throw error;
        }
        return body.data;
      });
    });
  }

  function postJson(path, payload, method) {
    return api(path, {
      method: method || 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });
  }

  function reloadAfter(message) {
    flash(message, false);
    window.setTimeout(function () { window.location.reload(); }, 400);
  }

  /* ---------- 顶部：退出登录 ---------- */
  function bindLogout(root) {
    var button = root.querySelector('[data-action="logout"]');
    if (!button) { return; }
    button.addEventListener('click', function () {
      postJson('/admin/logout', {}).then(function () {
        window.location.href = '/admin/login';
      }).catch(function (error) { flash(error.message, true); });
    });
  }

  /* ---------- ① 登录 ---------- */
  function bindLogin() {
    var form = document.getElementById('login-form');
    if (!form) { return; }
    form.addEventListener('submit', function (event) {
      event.preventDefault();
      var data = new FormData(form);
      postJson('/admin/login', {
        username: data.get('username'),
        password: data.get('password')
      }).then(function () {
        var next = data.get('next') || '/admin';
        window.location.href = next.indexOf('/admin') === 0 ? next : '/admin';
      }).catch(function (error) {
        flash(error.message, true);
      });
    });
  }

  /* ---------- ② 商品管理 ---------- */
  function itemPayload(row) {
    var payload = {};
    row.querySelectorAll('[data-field]').forEach(function (input) {
      if (input.type === 'checkbox') {
        payload.onShelf = input.checked ? 1 : 0;
      } else if (input.dataset.field === 'price' || input.dataset.field === 'order') {
        payload[input.dataset.field] = parseInt(input.value, 10) || 0;
      } else {
        payload[input.dataset.field] = input.value;
      }
    });
    return payload;
  }

  function bindItems(root) {
    root.querySelectorAll('[data-action="save-item"]').forEach(function (button) {
      button.addEventListener('click', function () {
        var row = button.closest('tr');
        var itemId = row.getAttribute('data-item-id');
        postJson('/admin/items/' + encodeURIComponent(itemId), itemPayload(row), 'PATCH')
          .then(function () { reloadAfter('已保存并写入操作日志：' + itemId); })
          .catch(function (error) { flash('保存失败：' + error.message, true); });
      });
    });

    var createForm = document.getElementById('create-item-form');
    if (createForm) {
      createForm.addEventListener('submit', function (event) {
        event.preventDefault();
        var data = new FormData(createForm);
        postJson('/admin/items', {
          id: data.get('id'),
          section: data.get('section'),
          name: data.get('name'),
          description: data.get('description') || null,
          price: parseInt(data.get('price'), 10) || 0,
          order: parseInt(data.get('order'), 10) || 0,
          onShelf: parseInt(data.get('onShelf'), 10)
        }).then(function (item) {
          window.location.href = '/admin/items';
          flash('已新增商品 ' + item.id, false);
        }).catch(function (error) { flash('新增失败：' + error.message, true); });
      });
    }

    root.querySelectorAll('[data-action="upload-icon"]').forEach(function (input) {
      input.addEventListener('change', function () {
        var file = input.files && input.files[0];
        if (!file) { return; }
        if (file.size > 512 * 1024) { flash('图标过大：' + file.size + ' 字节 > 512 KB', true); return; }
        var reader = new FileReader();
        reader.onload = function () {
          var base64 = String(reader.result).split(',')[1] || '';
          postJson('/admin/items/' + encodeURIComponent(input.dataset.itemId) + '/icon', {
            filename: file.name,
            dataBase64: base64
          }).then(function () { reloadAfter('图标已上传：' + input.dataset.itemId); })
            .catch(function (error) { flash('上传失败：' + error.message, true); });
        };
        reader.onerror = function () { flash('读取文件失败', true); };
        reader.readAsDataURL(file);
      });
    });
  }

  /* ---------- ⑥ 系统配置 ---------- */
  function bindConfig() {
    var form = document.getElementById('config-form');
    if (form) {
      form.addEventListener('submit', function (event) {
        event.preventDefault();
        var data = new FormData(form);
        postJson('/admin/config', {
          dailyCap: parseInt(data.get('dailyCap'), 10),
          badgesEnabled: parseInt(data.get('badgesEnabled'), 10)
        }, 'PUT').then(function (result) {
          reloadAfter(result.changed.length ? ('已保存：' + result.changed.join('、')) : '没有需要保存的改动');
        }).catch(function (error) { flash('保存失败：' + error.message, true); });
      });
    }

    var goalForm = document.getElementById('goal-form');
    if (goalForm) {
      goalForm.addEventListener('submit', function (event) {
        event.preventDefault();
        var rewards = [];
        goalForm.querySelectorAll('[data-goal-id]').forEach(function (input) {
          rewards.push({ id: input.dataset.goalId, reward: parseInt(input.value, 10) || 0 });
        });
        postJson('/admin/config', { goalRewards: rewards }, 'PUT').then(function (result) {
          reloadAfter(result.changed.length ? ('已保存：' + result.changed.join('、')) : '没有需要保存的改动');
        }).catch(function (error) { flash('保存失败：' + error.message, true); });
      });
    }
  }

  /* ---------- ① 改密码 ---------- */
  function bindPassword() {
    var form = document.getElementById('password-form');
    if (!form) { return; }
    form.addEventListener('submit', function (event) {
      event.preventDefault();
      var data = new FormData(form);
      var next = data.get('newPassword');
      if (next !== data.get('confirmPassword')) { flash('两次输入的新口令不一致', true); return; }
      postJson('/admin/password', {
        oldPassword: data.get('oldPassword'),
        newPassword: next
      }).then(function () {
        form.reset();
        flash('口令已更新（旧口令即时失效）；建议退出后重新登录', false);
      }).catch(function (error) { flash('改密码失败：' + error.message, true); });
    });
  }

  document.addEventListener('DOMContentLoaded', function () {
    bindLogout(document);
    bindLogin();
    bindItems(document);
    bindConfig();
    bindPassword();
  });
})();
