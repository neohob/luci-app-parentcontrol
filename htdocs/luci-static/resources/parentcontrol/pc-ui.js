/*
 * parentcontrol 公共 UI 助手（design.md D11 / 复审 F-3 的唯一实现）。
 * settings / ai_parse / index / stats 四个视图都从这里取 pcSetMsg / pcField /
 * pcPost / pcResetQuota，视图内不得再出现 setMsg / XHR.post / pcResetQuota 的
 * 第二份定义。文案一律由视图以参数传入：静态资源不经过 LuCI 模板处理，
 * 没有 translate()，所以这里不放任何用户可见字符串。
 */
(function (window, document) {
	'use strict';

	// R10/D5：新式控件可能把字段渲染成 textarea 也可能渲染成 input，两个都试。
	function pcField(suffix) {
		return document.querySelector('textarea[name$=".' + suffix + '"], input[name$=".' + suffix + '"]');
	}

	function pcSetMsg(el, text, ok) {
		if (!el) return;
		el.style.color = ok ? 'green' : 'red';
		el.textContent = text;
	}

	// XHR.post + CSRF token + JSON 解包的契约单点化；onOk 收到 (xhr, 已解析对象或 null)。
	function pcPost(url, data, onOk, onErr) {
		XHR.post(url, data, function (x) {
			var res = null;
			if (x && typeof x.responseText === 'string') {
				try { res = JSON.parse(x.responseText); } catch (e) { res = null; }
			} else if (x && typeof x === 'object') {
				res = x;
			}
			onOk(x, res);
		}, onErr);
	}

	// 重置当日额度并刷新页面。确认文案 / 动作 URL / token 由视图传入（文案要过
	// translate()，只能在模板侧给出）。
	function pcResetQuota(key, url, confirmText, token) {
		if (!key) return;
		if (!confirm(confirmText)) return;
		XHR.post(url, { key: key, token: token }, function () { location.reload(); });
	}

	// R10/D18：「绑定健康」的一键重绑 —— 把值写进指定字段（如 mac）并派发 change，
	// 让 LuCI 的控件状态跟着更新；**只写输入框，不自动保存**（保存仍由用户点按钮）。
	function pcSetField(suffix, value) {
		var el = pcField(suffix);
		if (!el) return false;
		el.value = value;
		if (typeof Event === 'function') {
			try { el.dispatchEvent(new Event('change')); } catch (e) { /* 老浏览器忽略 */ }
		}
		return true;
	}

	// ------------------------------------------------------------------
	// R9/D17：封锁名称行表（唯一 JS 实现）。
	//   · 行增删（「➕ 新增名称」/「删除」）
	//   · 把行序列化回隐藏 textarea（`名称|域名列表` 逐行）—— input/change 时 + 提交前兜底各同步一次
	//   · 逐行 AI 解析（POST 视图给的 url），沿用 ai_parse 时期的「追加不覆盖 + Array.isArray
	//     守卫 + 去重 + 红绿字提示」范式
	//   文案 / URL / CSRF token 全部由视图（apps_rows.htm）传入：静态资源不经过 translate()。
	// ------------------------------------------------------------------
	function splitTokens(v) {
		var out = [], parts = String(v || '').split(/[\s,;、，；]+/);
		for (var i = 0; i < parts.length; i++) if (parts[i] !== '') out.push(parts[i]);
		return out;
	}
	// 名称不得含 `|` 与换行（否则会把一行拆成两行/两列）——写入前统一清掉
	function cleanName(v) {
		return String(v || '').replace(/[\r\n\t|]+/g, ' ').replace(/\s+/g, ' ').replace(/^\s+|\s+$/g, '');
	}
	// 域名列表必须是单行（换行在 apps 里是行分隔符）
	function cleanDoms(v) {
		return String(v || '').replace(/[\r\n\t]+/g, ' ').replace(/^\s+|\s+$/g, '');
	}
	// res 里的数组一律过 Array.isArray + 字符串过滤：个别 LuCI 版本会把空表写成 {},
	// concat 会把对象当元素追加成 [object Object] 脏数据（F4 的老教训）。
	function toList(v) {
		if (!Array.isArray(v)) return [];
		var out = [];
		for (var i = 0; i < v.length; i++) {
			if (typeof v[i] === 'string' && v[i] !== '') out.push(v[i]);
		}
		return out;
	}

	function pcAppsRows(cfg) {
		var root = document.getElementById(cfg.root);
		if (!root) return null;
		var list = root.querySelector('[data-pc-app-list]');
		var store = document.querySelector('[data-pc-app-value]');
		if (!list || !store) return null;
		var msg = cfg.msg || {};

		function el(tag, cls, attrs) {
			var e = document.createElement(tag);
			if (cls) e.className = cls;
			if (attrs) for (var k in attrs) e.setAttribute(k, attrs[k]);
			return e;
		}
		function newRow(name, dom) {
			var row = el('div', 'pc-app-row', { 'data-pc-app-row': '' });
			var ni = el('input', 'pc-app-name', { type: 'text', placeholder: cfg.namePh || '' });
			ni.value = name || '';
			var ai = el('button', 'cbi-button pc-app-ai', { type: 'button', 'data-pc-app-ai': '' });
			ai.appendChild(document.createTextNode(cfg.aiText || 'AI'));
			var di = el('input', 'pc-app-dom', { type: 'text', placeholder: cfg.domPh || '' });
			di.value = dom || '';
			var del = el('button', 'cbi-button pc-app-del', { type: 'button', 'data-pc-app-del': '' });
			del.appendChild(document.createTextNode(cfg.delText || '×'));
			row.appendChild(ni); row.appendChild(ai); row.appendChild(di); row.appendChild(del);
			row.appendChild(el('span', 'pc-app-msg'));
			return row;
		}
		function rowNodes() { return list.querySelectorAll('[data-pc-app-row]'); }
		// 行 → textarea：`名称|域名列表` 逐行；两栏都空的行丢掉（不留空行）
		function sync() {
			var out = [], rs = rowNodes();
			for (var i = 0; i < rs.length; i++) {
				var n = rs[i].querySelector('.pc-app-name');
				var d = rs[i].querySelector('.pc-app-dom');
				var name = cleanName(n ? n.value : '');
				var dom = cleanDoms(d ? d.value : '');
				if (name === '' && dom === '') continue;
				out.push(name + '|' + dom);
			}
			store.value = out.join('\n');
		}
		function ai(row) {
			var n = row.querySelector('.pc-app-name');
			var d = row.querySelector('.pc-app-dom');
			var m = row.querySelector('.pc-app-msg');
			var text = n ? String(n.value) : '';
			if (text.replace(/[\s,;、，；]+/g, '') === '') {
				pcSetMsg(m, msg.emptyName || '', false);
				return;
			}
			pcSetMsg(m, msg.parsing || '', true);
			pcPost(cfg.url, { text: text, token: cfg.token }, function (x, res) {
				if (!res || !res.ok) {
					pcSetMsg(m, (res && res.error) ? res.error : (msg.fail || ''), false);
					return;
				}
				var items = toList(res.direct).concat(toList(res.domains));
				// A9/F-1 第二道防线：有回应但既无直用项也无新域名 → 红字，且不动这一行
				if (items.length === 0) {
					pcSetMsg(m, msg.noResult || '', false);
					return;
				}
				var existing = splitTokens(d ? d.value : '');
				var seen = {}, add = [];
				for (var i = 0; i < existing.length; i++) seen[existing[i]] = true;
				for (var j = 0; j < items.length; j++) {
					if (seen[items[j]]) continue;
					seen[items[j]] = true;
					add.push(items[j]);
				}
				// 追加而不是覆盖：原有的项一个都不丢（已存在的不重复添加）
				if (add.length && d) d.value = existing.concat(add).join(',');
				sync();
				pcSetMsg(m, (msg.added || '') + add.length + (msg.items || '')
					+ (res.truncated ? (msg.truncated || '') : ''), true);
			}, function () {
				pcSetMsg(m, msg.netFail || '', false);
			});
		}

		root.addEventListener('click', function (ev) {
			var t = ev.target;
			if (!t || !t.closest) return;
			var add = t.closest('[data-pc-app-add]');
			if (add && root.contains(add)) {
				list.appendChild(newRow('', ''));
				var ni = list.lastChild.querySelector('.pc-app-name');
				if (ni) ni.focus();
				sync();
				return;
			}
			var del = t.closest('[data-pc-app-del]');
			if (del) {
				var row = del.closest('[data-pc-app-row]');
				if (row) list.removeChild(row);
				sync();
				return;
			}
			var ab = t.closest('[data-pc-app-ai]');
			if (ab) {
				var r = ab.closest('[data-pc-app-row]');
				if (r) ai(r);
			}
		});
		list.addEventListener('input', sync);
		list.addEventListener('change', sync);
		// 提交前兜底再同步一次（键盘外的路径，例如浏览器自动填充）
		var form = root.closest ? root.closest('form') : null;
		if (form) form.addEventListener('submit', sync);
		document.addEventListener('submit', sync, true);
		sync();
		return { sync: sync, addRow: function (n, d) { list.appendChild(newRow(n, d)); sync(); } };
	}

	window.pcField = pcField;
	window.pcSetMsg = pcSetMsg;
	window.pcPost = pcPost;
	window.pcResetQuota = pcResetQuota;
	window.pcSetField = pcSetField;
	window.pcAppsRows = pcAppsRows;
})(window, document);
