// Keep the original menu under its select controller so filtering, creation,
// selection and submitted hidden inputs continue to use the established code.
export function openSelectSheet(owner) {
  const template = owner.element.closest('[data-controller~="quick-entry"]')?.querySelector("[data-select-sheet-template]");
  if (!template) return false;
  if (owner.selectSheet) return true;

  const fragment = template.content.cloneNode(true);
  const wrapper = fragment.firstElementChild;
  const dialog = wrapper.querySelector("dialog");
  const body = wrapper.querySelector("[data-select-sheet-body]");
  const menu = owner.menuTarget;
  const placeholder = document.createComment("select menu");
  menu.before(placeholder);
  owner.selectSheet = { wrapper, dialog, menu, placeholder, classes: menu.className, style: menu.getAttribute("style") };
  dialog.selectSheetOwner = owner;
  owner.element.appendChild(fragment);
  body.appendChild(menu);
  menu.className = "relative w-full bg-container p-1 [&_[role=listbox]]:max-h-none [&_input]:text-base";
  menu.removeAttribute("style");
  dialog.showModal();
  requestAnimationFrame(() => menu.querySelector('input[type="search"]')?.focus({ preventScroll: true }));
  return true;
}

export function closeSelectSheet(owner) {
  const sheet = owner.selectSheet;
  if (!sheet) return;
  owner.selectSheet = null;
  sheet.placeholder.replaceWith(sheet.menu);
  sheet.menu.className = sheet.classes;
  if (sheet.style === null) sheet.menu.removeAttribute("style");
  else sheet.menu.setAttribute("style", sheet.style);
  sheet.dialog.selectSheetOwner = null;
  sheet.dialog.close();
  sheet.wrapper.remove();
  if (owner.element.isConnected) {
    if (owner.focusTriggerWithoutReopening) owner.focusTriggerWithoutReopening();
    else owner.buttonTarget.focus({ preventScroll: true });
  }
}
