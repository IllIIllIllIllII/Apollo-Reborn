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

    // Isolation must succeed before native code exposes the browser. Its close
    // event immediately masks the portal and carries the document generation.
    let dialog = null;
    let portalAttributes = {};
    let shadowStyles = [];
    let pageStyles = [];
    let events = {};
    let messages = [];
    globalThis.document = {
        querySelector: selector => {
            record(selector === '[dialog-id="award-dialog"]');
            return dialog;
        },
        getElementById: () => null,
        createElement: () => ({}),
        documentElement: {appendChild: value => pageStyles.push(value)}
    };
    globalThis.requestAnimationFrame = callback => callback();
    let observers = [];
    globalThis.MutationObserver = class {
        constructor(callback) {this.callback=callback;this.disconnected=false;observers.push(this);}
        observe() {}
        disconnect() {this.disconnected=true;}
    };
    globalThis.setTimeout = callback => {callback();return 0;};
    globalThis.clearTimeout = () => {};
    globalThis.window = {webkit:{messageHandlers:{apolloAwardSheet:{postMessage: value => messages.push(value)}}}};
    record(await isolateChooser(isolationStyle,7,11) === false);
    const portal = {
        isConnected: true,
        querySelector: () => null,
        setAttribute: (key,value) => {portalAttributes[key] = value;},
        removeAttribute: key => {delete portalAttributes[key];}
    };
    dialog = {
        open: false,
        localName: 'rpl-dialog-sheet',
        updateComplete: Promise.resolve(),
        elementRef: {updateComplete: Promise.resolve()},
        portalContainer: portal,
        panelRef: {value:{isConnected:true}},
        portalShadowRoot: {appendChild: value => shadowStyles.push(value)},
        addEventListener: (name,callback) => {events[name] = callback;}
    };
    record(await isolateChooser(isolationStyle,7,11) === false);
    dialog.open = true;
    portal.isConnected = false;
    record(await isolateChooser(isolationStyle,7,11) === false);
    portal.isConnected = true;
    record(await isolateChooser(isolationStyle,7,11) === true);
    record(Object.hasOwn ? Object.hasOwn(portalAttributes,'data-apollo-award-portal') : 'data-apollo-award-portal' in portalAttributes);
    record(pageStyles.length === 1 && pageStyles[0].textContent === isolationStyle);
    record(shadowStyles.length === 1 && shadowStyles[0].textContent.includes('transform:none!important'));
    const replacementAttributes = {};
    const replacementStyles = [];
    dialog.portalContainer = {
        isConnected:true,
        querySelector:()=>null,
        setAttribute:(key,value)=>{replacementAttributes[key]=value;},
        removeAttribute:key=>{delete replacementAttributes[key];}
    };
    dialog.portalShadowRoot = {appendChild:value=>replacementStyles.push(value)};
    const replacementObserver = observers[observers.length-1];
    replacementObserver.callback();
    record(!('data-apollo-award-portal' in portalAttributes) && 'data-apollo-award-portal' in replacementAttributes);
    record(replacementStyles.length === 1);
    replacementObserver.callback();
    record(replacementStyles.length === 1);
    events['rpl-dialog-sheet:hide']({target:{}});
    record(messages.length === 0);
    events['rpl-dialog-sheet:hide']({target:dialog});
    record(!('data-apollo-award-portal' in replacementAttributes));
    record(replacementObserver.disconnected);
    record(messages.length === 1 && messages[0].action === 'close' && messages[0].generation === 7 && messages[0].navigationGeneration === 11);
    events['rpl-dialog-sheet:after-hide']({target:dialog});
    record(messages.length === 1);
    finish();
})().catch(() => record(false));
