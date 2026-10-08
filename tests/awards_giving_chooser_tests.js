// Run the production chooser script in JavaScriptCore with a small DOM double.
// No network and no order endpoint: only the verified full-chooser method exists.
(async function () {
    let expectedSelector;
    let control;
    let calls = [];
    let definedTags = [];
    globalThis.document = { querySelector(selector) {
        record(selector === expectedSelector);
        return control;
    }};
    globalThis.customElements = { whenDefined(tag) {
        definedTags.push(tag);
        return Promise.resolve();
    }};
    globalThis.setTimeout = () => 0;
    const makeControl = (fullName) => ({
        isConnected: true,
        disabled: false,
        hasAttribute: () => false,
        scrollIntoView: () => {},
        click: () => record(false),
        awardController: {
            getThingId: () => fullName,
            activateDialog: async options => calls.push(options)
        }
    });

    expectedSelector = 'shreddit-post-overflow-menu[post-id="t3_1q02umz"]';
    control = makeControl('t3_1q02umz');
    record(await openChooser('t3_1q02umz') === true);
    record(calls.length === 1 && calls[0].skipQuickGivePopover === true && calls[0].animateOnOpen === true);
    record(definedTags[0] === 'shreddit-post-overflow-menu');

    expectedSelector = 'award-button[thing-id="t1_nwutqka"]';
    control = makeControl('t1_nwutqka');
    record(await openChooser('t1_nwutqka') === true);
    record(calls.length === 2 && calls[1].skipQuickGivePopover === true);
    record(definedTags[1] === 'award-button');

    control = null;
    record(await openChooser('t1_nwutqka') === false);
    control = makeControl('t1_other');
    record(await openChooser('t1_nwutqka') === false);
    control = makeControl('t1_nwutqka');
    control.disabled = true;
    record(await openChooser('t1_nwutqka') === false);
    control.disabled = false;
    control.hasAttribute = name => name === 'disabled';
    record(await openChooser('t1_nwutqka') === false);
    control.hasAttribute = () => false;
    control.isConnected = false;
    record(await openChooser('t1_nwutqka') === false);
    control = makeControl('t1_nwutqka');
    delete control.awardController.activateDialog;
    record(await openChooser('t1_nwutqka') === false);
    delete control.awardController;
    record(await openChooser('t1_nwutqka') === false);
    record(await openChooser('t1_bad"][thing-id="t1_other') === false);
    record(await openChooser('t5_community') === false);
    record(calls.length === 2);
    finish();
})().catch(() => record(false));
