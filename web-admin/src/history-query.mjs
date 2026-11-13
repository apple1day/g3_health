// Every filter is part of the pagination scope. Changing sources or dates starts
// a fresh server query; filtering only the currently loaded rows would lose history.
export function historyScope({ kind = '', from = '', to = '', sourceID = '' }) {
 return JSON.stringify([kind, from, to, sourceID]);
}
export function historyQuery({ kind = '', from = '', to = '', sourceID = '' }, cursor = '') {
 return new URLSearchParams({ kind, from, to, sourceID, limit: '50', cursor }).toString();
}
