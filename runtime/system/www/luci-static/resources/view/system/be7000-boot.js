'use strict';
'require view';
'require fs';
'require rpc';
'require ui';

var reboot = rpc.declare({ object: 'system', method: 'reboot' });

function command(action) {
    return fs.exec('/usr/sbin/be7000-boot', [ action ]).then(function(result) {
        if (result.code !== 0)
            throw new Error(result.stderr || _('Could not update boot settings.'));
        return result.stdout;
    });
}

return view.extend({
    load: function() {
        return command('status').then(JSON.parse);
    },

    render: function(state) {
        var writable = L.hasViewPermission();
        var setMode = function(action) {
            return command(action).then(function() { window.location.reload(); });
        };
        return E('div', {}, [
            E('h2', {}, _('Boot system')),
            E('p', {}, _('Without the USB drive, the router starts Xiaomi firmware. Three unconfirmed OpenWrt boots pause automatic startup.')),
            !state.installed ? E('p', { 'class': 'alert-message warning' },
                _('Autostart is not installed. Run the installer in Xiaomi firmware and select automatic startup.')) : '',
            E('p', {}, _('OpenWrt autostart: %s').format(state.enabled ? _('Enabled') : _('Disabled'))),
            E('p', {}, _('Unconfirmed attempts: %d / 3').format(state.attempts)),
            E('p', {}, state.xiaomi_once ? _('The next boot will stay in Xiaomi firmware.') : ''),
            E('div', { 'class': 'cbi-page-actions' }, [
                E('button', { 'class': 'btn cbi-button-action', 'disabled': (!writable || !state.installed) || null,
                    'click': ui.createHandlerFn(this, function() { return setMode(state.enabled ? 'disable' : 'enable'); })
                }, state.enabled ? _('Disable autostart') : _('Enable autostart')),
                ' ',
                E('button', { 'class': 'btn cbi-button-action', 'disabled': (!writable || !state.installed) || null,
                    'click': ui.createHandlerFn(this, function() { return setMode('retry'); })
                }, _('Reset attempts and enable')),
                ' ',
                E('button', { 'class': 'btn cbi-button-negative', 'disabled': !writable || null,
                    'click': ui.createHandlerFn(this, function() {
                        ui.showModal(_('Reboot into Xiaomi'), [
                            E('p', {}, _('The USB drive can stay connected. OpenWrt autostart will be skipped once.')),
                            E('div', { 'class': 'right' }, [
                                E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
                                ' ',
                                E('button', { 'class': 'btn cbi-button-negative', 'click': ui.createHandlerFn(this, function() {
                                    return command('xiaomi-once').then(reboot).then(function() {
                                        ui.showModal(_('Rebooting…'), E('p', {}, _('Reconnect to Xiaomi firmware at its configured LAN address.')));
                                    });
                                }) }, _('Reboot'))
                            ])
                        ]);
                    })
                }, _('Reboot into Xiaomi'))
            ])
        ]);
    },

    handleSaveApply: null,
    handleSave: null,
    handleReset: null
});
