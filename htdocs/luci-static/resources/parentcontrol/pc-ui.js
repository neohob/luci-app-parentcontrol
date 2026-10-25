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

	/* 统计页「设备每日用量」矩阵：点设备行展开/收起它的条目子行。
	   只用 querySelectorAll 现查（不缓存节点引用，避免 LuCI 表单重渲染后失效）；
	   只切 style.display 与首列箭头文本，绝不回写 innerHTML（pcdata 转义结果不能被二次解析）；
	   不持久化（刷新回到全折叠，不写 cookie/localStorage）。
	   data-pc-dev 只含整数（模板保证）；这里再钉一次数字形态，选择器串不吃任何外来字符。 */
	function pcMatrixToggle(tr) {
		/* A19/L6：行本身带 onclick，拖选行内文字（设备名 / 数字）时 mouseup 会顺手
		   触发展开/收起，把用户刚选好的选区弄丢。选中文本非空 ⇒ 一律不动。
		   只在 getSelection 存在时判（老浏览器没有它，行为退回原样）。 */
		if (window.getSelection) {
			var _sel = window.getSelection();
			if (_sel && String(_sel) !== '') { return; }
		}
		var i = tr && tr.getAttribute('data-pc-dev');
		if (!i || !/^[0-9]+$/.test(i)) { return; }
		var rows = document.querySelectorAll('[data-pc-owner="' + i + '"]');
		var open = false;
		for (var n = 0; n < rows.length; n++) {
			if (rows[n].style.display === 'none') { open = true; break; }
		}
		for (var m = 0; m < rows.length; m++) {
			rows[m].style.display = open ? '' : 'none';
		}
		var caret = tr.querySelector('.pc-matrix-caret');
		if (caret) { caret.textContent = open ? '▾' : '▸'; }
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

	// ------------------------------------------------------------------
	// 第 11k 轮（A95-2）：设备行表（唯一 JS 实现）。
	//   · 行增删（「➕ 新增设备」/「删除」）
	//   · 把行序列化为 `MAC|IP` 逐行写回隐藏 textarea —— input/change 时 + 提交前兜底各同步一次
	//   · 写入前把行内的 `|` 与换行清成空格（否则会把一行拆成两列/两行）+ 去首尾空白；
	//     **不做**大小写归一（原样回写用户输入，归一只用于服务端比较/判定）
	//   文案 / 占位符全部由视图（clients_rows.htm）传入：静态资源不经过 translate()。
	// ------------------------------------------------------------------
	function pcCleanCell(v) {
		return String(v || '').replace(/[\r\n\t|]+/g, ' ').replace(/^\s+|\s+$/g, '');
	}

	function pcClientsRows(cfg) {
		var root = document.getElementById(cfg.root);
		if (!root) return null;
		var list = root.querySelector('[data-pc-client-list]');
		var store = document.querySelector('[data-pc-clients-value]');
		if (!list || !store) return null;

		function el(tag, cls, attrs) {
			var e = document.createElement(tag);
			if (cls) e.className = cls;
			if (attrs) for (var k in attrs) e.setAttribute(k, attrs[k]);
			return e;
		}
		function newRow(mac, ip) {
			var row = el('div', 'pc-client-row', { 'data-pc-client-row': '' });
			var mi = el('input', 'pc-client-mac', { type: 'text', placeholder: cfg.macPh || '' });
			// A133-2b（第 11k-8 轮 D55）：JS 新增的行也必须带 list —— 否则用户点「➕ 新增设备」
			// 后又变回纯手打，会认为没修好。macList 缺省时**不得**设置该属性（否则渲染出
			// 指向不存在 id 的悬空属性；删掉 datalist 或其它调用点不传时就会出问题）。
			if (cfg.macList) mi.setAttribute('list', cfg.macList);
			mi.value = mac || '';
			var ii = el('input', 'pc-client-ip', { type: 'text', placeholder: cfg.ipPh || '' });
			ii.value = ip || '';
			var del = el('button', 'cbi-button pc-client-del', { type: 'button', 'data-pc-client-del': '' });
			del.appendChild(document.createTextNode(cfg.delText || '×'));
			row.appendChild(mi); row.appendChild(ii); row.appendChild(del);
			return row;
		}
		function rowNodes() { return list.querySelectorAll('[data-pc-client-row]'); }
		// 行 → textarea：`MAC|IP` 逐行；两栏都空的行丢掉（不留空行）
		function sync() {
			var out = [], rs = rowNodes();
			for (var i = 0; i < rs.length; i++) {
				var m = rs[i].querySelector('.pc-client-mac');
				var p = rs[i].querySelector('.pc-client-ip');
				var mac = pcCleanCell(m ? m.value : '');
				var ip = pcCleanCell(p ? p.value : '');
				if (mac === '' && ip === '') continue;
				out.push(mac + '|' + ip);
			}
			store.value = out.join('\n');
		}

		root.addEventListener('click', function (ev) {
			var t = ev.target;
			if (!t || !t.closest) return;
			var add = t.closest('[data-pc-client-add]');
			if (add && root.contains(add)) {
				list.appendChild(newRow('', ''));
				var mi = list.lastChild.querySelector('.pc-client-mac');
				if (mi) mi.focus();
				sync();
				return;
			}
			var del = t.closest('[data-pc-client-del]');
			if (del) {
				var row = del.closest('[data-pc-client-row]');
				if (row) list.removeChild(row);
				sync();
			}
		});
		list.addEventListener('input', sync);
		list.addEventListener('change', sync);
		// 提交前兜底再同步一次（键盘外的路径，例如浏览器自动填充）
		var form = root.closest ? root.closest('form') : null;
		if (form) form.addEventListener('submit', sync);
		document.addEventListener('submit', sync, true);
		sync();
		return { sync: sync, addRow: function (n, p) { list.appendChild(newRow(n, p)); sync(); } };
	}

	// A95-3：一键重绑 —— 只把「oldMac 那一行」的 MAC 输入框改写为 newMac（保留该行 IP、
	// 不动其它行）；只写输入框，不自动保存（保存仍由用户点页面底部的按钮）。
	function pcClientsRebind(oldMac, newMac) {
		var want = pcCleanCell(oldMac).toLowerCase();
		if (want === '') return false;
		var rows = document.querySelectorAll('[data-pc-client-row]');
		for (var i = 0; i < rows.length; i++) {
			var mi = rows[i].querySelector('.pc-client-mac');
			if (!mi) continue;
			if (pcCleanCell(mi.value).toLowerCase() !== want) continue;
			mi.value = newMac;
			if (typeof Event === 'function') {
				// A129（第 11k-7 轮 F-B）：必须冒泡 —— pcClientsRows 的 sync 监听委托在
				// #pc-clients 根节点上，Event 构造器默认 bubbles:false ⇒ change 到不了根，
				// 隐藏 textarea 不即时同步（靠 submit 兜底；form.submit() 之类路径会写回旧 MAC）。
				try { mi.dispatchEvent(new Event('change', { bubbles: true })); } catch (e) { /* 老浏览器忽略 */ }
			}
			return true;
		}
		return false;
	}

	window.pcField = pcField;
	window.pcSetMsg = pcSetMsg;
	window.pcPost = pcPost;
	window.pcResetQuota = pcResetQuota;
	window.pcMatrixToggle = pcMatrixToggle;
	window.pcAppsRows = pcAppsRows;
	window.pcClientsRows = pcClientsRows;
	window.pcClientsRebind = pcClientsRebind;
})(window, document);
