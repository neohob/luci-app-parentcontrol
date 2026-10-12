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

	window.pcField = pcField;
	window.pcSetMsg = pcSetMsg;
	window.pcPost = pcPost;
	window.pcResetQuota = pcResetQuota;
})(window, document);
