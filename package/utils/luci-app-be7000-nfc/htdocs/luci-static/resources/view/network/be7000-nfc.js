'use strict';
'require view';
'require rpc';
'require ui';

var status = rpc.declare({ object: 'be7000.nfc', method: 'status', expect: {} });
var save = rpc.declare({ object: 'be7000.nfc', method: 'set', params: ['enabled', 'iface', 'mode', 'text', 'uri', 'manual_ssid', 'manual_key', 'security'], expect: {} });

return view.extend({
	load: function() { return status(); },
	render: function(info) {
		var enabled = E('input', { type: 'checkbox', checked: info.enabled ? '' : null, autocomplete: 'off' });
		var mode = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { value: 'wifi' }, 'Wi-Fi роутера'), E('option', { value: 'text' }, 'Текст'),
			E('option', { value: 'uri' }, 'Ссылка (URI)'), E('option', { value: 'manual' }, 'Wi-Fi вручную')
		]);
		mode.value = ['text', 'uri', 'manual'].includes(info.mode) ? info.mode : 'wifi';
		function field(label, input) {
			return E('p', {}, [ E('label', { style: 'display:block;margin-bottom:.5em' }, label), input ]);
		}
		var uri = E('input', { type: 'text', placeholder: 'https://example.com', style: 'width:100%', value: info.uri || '' });
		var uriRow = field('Ссылка', uri);
		var ssid = E('input', { type: 'text', value: info.manual_ssid || '', autocomplete: 'off' });
		var key = E('input', { type: 'password', value: info.manual_key || '', autocomplete: 'new-password' });
		var security = E('select', {}, [ E('option', { value: 'wpa2' }, 'WPA2-Personal'), E('option', { value: 'none' }, 'Без пароля') ]);
		security.value = info.security === 'none' ? 'none' : 'wpa2';
		var keyRow = field('Пароль', key);
		var manualRow = E('div', {}, [ field('Имя сети (SSID)', ssid), field('Защита', security), keyRow ]);
		var text = E('textarea', { rows: 6, style: 'width:100%;box-sizing:border-box', autocomplete: 'off' });
		text.value = info.text || '';
		var counter = E('small');
		var textRow = E('div', {}, [ text, counter ]);
		var select = E('select', { 'class': 'cbi-input-select', style: 'max-width:100%' },
			(info.aps || []).map(function(ap) {
				return E('option', { value: ap.id }, ap.ssid + ' · ' + ap.radio + (ap.disabled ? ' (выключена)' : ''));
			}));
		if ((info.aps || []).some(function(ap) { return ap.id === info.iface; })) select.value = info.iface;
		var wifiRow = E('p', {}, [ E('label', { style: 'display:block;margin-bottom:.5em' }, 'Точка доступа'), select ]);
		var note = E('p', { 'class': 'cbi-section-descr' });
		var result = E('p', { role: 'status' }, info.error || '');
		var button = E('button', { 'class': 'cbi-button cbi-button-action', click: ui.createHandlerFn(this, function() {
			button.disabled = true;
			return save(enabled.checked, select.value || '', mode.value, text.value, uri.value, ssid.value, key.value, security.value).then(function(reply) {
				if (!reply.ok) throw new Error(reply.error || 'Не удалось записать NFC.');
				result.textContent = enabled.checked ? 'Записано.' : 'NFC отключён.';
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, err.message), 'error');
			}).finally(update);
		}) }, 'Сохранить');
		function update() {
			var isText = mode.value === 'text';
			var bytes = new TextEncoder().encode(text.value).length;
			wifiRow.hidden = mode.value !== 'wifi';
			textRow.hidden = !isText;
			uriRow.hidden = mode.value !== 'uri';
			manualRow.hidden = mode.value !== 'manual';
			keyRow.hidden = security.value === 'none';
			[uri, ssid, key, security].forEach(function(input) { input.disabled = !enabled.checked; });
			counter.textContent = bytes + ' / 1900 байт';
			text.disabled = !enabled.checked;
			mode.disabled = !enabled.checked;
			select.disabled = !enabled.checked;
			var size = function(value) { return new TextEncoder().encode(value).length; };
			var invalid = mode.value === 'text' ? !bytes || bytes > 1900 :
				mode.value === 'uri' ? !/^[a-zA-Z][a-zA-Z0-9+.-]*:[^\s\x00-\x1f\x7f]*$/.test(uri.value) || size(uri.value) > 1900 :
				mode.value === 'manual' ? !size(ssid.value) || size(ssid.value) > 32 ||
					(security.value !== 'none' && !((size(key.value) >= 8 && size(key.value) <= 63) || /^[a-fA-F0-9]{64}$/.test(key.value))) : !(info.aps || []).length;
			button.disabled = !info.available || (enabled.checked && invalid);
			var ap = (info.aps || []).find(function(item) { return item.id === select.value; });
			note.textContent = !info.available ? 'NFC недоступен.' :
				!enabled.checked || mode.value !== 'wifi' ? '' :
				ap && ap.disabled ? 'Точка доступа выключена.' :
				ap && /^sae(?:$|\+|-ext)/.test(ap.encryption) ? '' :
				ap && !ap.compatible ? 'Этот тип защиты не поддерживается.' : '';
			note.hidden = !note.textContent;
		}
		enabled.addEventListener('change', update);
		select.addEventListener('change', update);
		mode.addEventListener('change', update);
		text.addEventListener('input', update);
		[uri, ssid, key, security].forEach(function(input) { input.addEventListener('input', update); input.addEventListener('change', update); });
		update();
		return E('div', {}, [
			E('h2', {}, 'NFC'),
			E('div', { 'class': 'cbi-section', style: 'max-width:760px;padding:1.2em' }, [
				E('p', {}, E('label', {}, [ enabled, ' Включить NFC' ])),
				E('p', {}, [ E('label', { style: 'display:block;margin-bottom:.5em' }, 'Содержимое метки'), mode ]),
				wifiRow, textRow, uriRow, manualRow,
				note,
				button, result
			])
		]);
	},
	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
