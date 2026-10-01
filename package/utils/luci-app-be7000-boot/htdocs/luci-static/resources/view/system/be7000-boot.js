'use strict';
'require view';
'require fs';
'require rpc';
'require ui';

var reboot = rpc.declare({ object: 'system', method: 'reboot', expect: { result: 0 } });

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
        return E('div', {}, [
            E('h2', {}, _('Reboot into Xiaomi')),
            E('p', {}, _('The USB drive can stay connected. OpenWrt autostart will be skipped once.')),
            state.xiaomi_once ? E('p', {}, _('The next boot will stay in Xiaomi firmware.')) : '',
            E('button', {
                'class': 'btn cbi-button-negative',
                'disabled': !L.hasViewPermission() || null,
                'click': ui.createHandlerFn(this, function() {
                    ui.showModal(_('Reboot into Xiaomi'), [
                        E('p', {}, _('Reboot the router now?')),
                        E('div', { 'class': 'right' }, [
                            E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
                            ' ',
                            E('button', {
                                'class': 'btn cbi-button-negative',
                                'click': ui.createHandlerFn(this, function() {
                                    return command('xiaomi-once').then(reboot).then(function(result) {
                                        if (result !== 0)
                                            throw new Error(_('Could not reboot the router.'));
                                        ui.showModal(_('Rebooting…'), E('p', {}, _('Reconnect to Xiaomi firmware at its configured LAN address.')));
                                    });
                                })
                            }, _('Reboot'))
                        ])
                    ]);
                })
            }, _('Reboot into Xiaomi'))
        ]);
    },

    handleSaveApply: null,
    handleSave: null,
    handleReset: null
});
