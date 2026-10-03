'use strict';
'require view';
'require rpc';
'require ui';

var getStatus = rpc.declare({ object: 'be7000.wifi', method: 'status', expect: {} });
var setMode = rpc.declare({ object: 'be7000.wifi', method: 'set', params: [ 'mode', 'mlo' ], expect: {} });
var callReboot = rpc.declare({ object: 'system', method: 'reboot', expect: { result: 0 } });

return view.extend({
	load: function() { return getStatus(); },
	render: function(data) {
		var checkbox = E('input', { type: 'checkbox', autocomplete: 'off', checked: data.selected === 'dual' ? '' : null });
		var mloCheckbox = E('input', { type: 'checkbox', autocomplete: 'off', checked: data.selected === 'dual' && data.mlo ? '' : null });
		var busy = false;
		var rebooting = false;
		var message = E('p', { role: 'status' });
		var description = E('p');
		var currentMode = E('p');
		var modeName = function(mode, mlo) { return mode === 'dual' ? (mlo ? _('One MLO network (two links)') : _('Two independent 5 GHz networks')) : _('One 5 GHz radio'); };
		function save() {
			busy = true;
			updateControls();
			return setMode(checkbox.checked ? 'dual' : 'single', checkbox.checked && mloCheckbox.checked).then(function(result) {
				if (result.error) throw new Error(({
					unavailable: _('The boot files for switching radio modes are not installed.'),
					busy: _('Another change is being saved. Try again.'),
					no_radio: _('The main 5 GHz access point was not found.'),
					bad_mode: _('Invalid radio mode.'),
					mlo_security: _('MLO requires a WPA2-Personal or WPA3-Personal network with an 8–63 character password. The MLO network will use WPA3.')
				})[result.error] || result.error);
				data = result;
				updateMessage();
				if (!data.pending) {
					message.textContent = _('Applied.');
					return;
				}
				return callReboot().then(function(code) {
					if (code !== 0) throw new Error(_('The reboot command failed with code %d').format(code));
					rebooting = true;
					ui.showModal(_('Rebooting…'), [ E('p', { 'class': 'spinning' }, _('Waiting for device...')) ]);
					ui.awaitReconnect();
				});
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, err.message), 'error');
			}).finally(function() {
				busy = rebooting;
				updateControls();
			});
		}
		var applyButton = E('button', {
			'class': 'cbi-button cbi-button-action important',
			click: save
		}, _('Save and reboot'));
		function updateMessage() {
			currentMode.textContent = _('Current mode: %s').format(modeName(data.current, data.current_mlo));
			message.textContent = data.pending
				? _('Saved. Reboot to apply.') : '';
		}
		function updateControls() {
			applyButton.textContent = data.current === 'dual' && checkbox.checked ? _('Save and apply') : _('Save and reboot');
			applyButton.disabled = checkbox.disabled = busy || !data.available || !L.hasViewPermission();
			mloCheckbox.disabled = checkbox.disabled || !checkbox.checked;
			description.textContent = !checkbox.checked
				? _('After reboot: one 5 GHz network with the original channel width.')
				: mloCheckbox.checked
					? _('One MLO network with WPA3 and two 5 GHz links. Default: channel 36 at 160 MHz and channel 149 at 80 MHz.')
					: _('Two separate 5 GHz networks, each with its own name.');
		}
		checkbox.addEventListener('change', function() {
			if (!checkbox.checked) mloCheckbox.checked = false;
			updateControls();
		});
		mloCheckbox.addEventListener('change', updateControls);
		updateMessage();
		updateControls();
		return E('div', { 'class': 'cbi-map', style: 'max-width: 760px' }, [
			E('h2', {}, _('5 GHz mode')),
			E('div', { 'class': 'cbi-section' }, [
				currentMode,
				E('label', { style: 'display: flex; align-items: center; gap: .7em; margin: 1.5em 0' }, [
					checkbox, E('strong', {}, _('Enable a second 5 GHz radio'))
				]),
				E('label', { style: 'display: flex; align-items: center; gap: .7em; margin: 1.5em 0' }, [
					mloCheckbox, E('strong', {}, _('Combine the radios into MLO (MLD)'))
				]),
				description,
				E('p', {}, _('Changing the number of radios requires a reboot. Switching MLO with two active radios only restarts Wi-Fi.')),
				!data.available ? E('p', { 'class': 'alert-message warning' }, _('The boot files for switching radio modes are not installed.')) : '',
				applyButton, message
			])
		]);
	},
	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
