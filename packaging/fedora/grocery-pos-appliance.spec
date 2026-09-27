Name:           grocery-pos-appliance
Version:        0.0.0
Release:        0.2.dev%{?dist}
Summary:        Fedora Kinoite lifecycle assets for Grocery POS registers
License:        LicenseRef-Project-Undecided
URL:            https://github.com/adarj/grocery-pos-platform
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch
Requires:       grocery-pos-core >= 0.0.0-0.5.dev
Requires:       coreutils
Requires:       flatpak
Requires:       kde-settings-plasmalogin
Requires:       ostree
Requires:       plasma-login-manager
Requires:       rpm-ostree
Requires:       shadow-utils
Requires:       systemd

%description
Declarative host assets and explicit technician tooling for provisioning a
Fedora Kinoite Grocery POS register. The package contains no register database,
store catalog, register configuration, credentials, or mutable machine state.

%prep
%autosetup

%build
# The appliance integration is architecture-independent service/configuration
# content. Mutable state is created only by explicit provisioning.

%install
install -D -m 0755 packaging/fedora/grocery-pos-appliance \
  %{buildroot}/usr/bin/grocery-pos-appliance
install -D -m 0755 packaging/fedora/configure-kiosk \
  %{buildroot}/usr/libexec/grocery-pos-appliance/configure-kiosk
install -D -m 0644 packaging/fedora/plasmalogin-grocery-pos.conf \
  %{buildroot}/usr/libexec/grocery-pos-appliance/plasmalogin-grocery-pos.conf
install -D -m 0644 packaging/fedora/kscreenlockerrc \
  %{buildroot}/usr/libexec/grocery-pos-appliance/kscreenlockerrc
install -D -m 0644 packaging/fedora/powerdevilrc \
  %{buildroot}/usr/libexec/grocery-pos-appliance/powerdevilrc
install -D -m 0644 packaging/fedora/grocery-pos-terminal.service \
  %{buildroot}/usr/lib/systemd/user/grocery-pos-terminal.service

%files
%defattr(-,root,root,-)
/usr/bin/grocery-pos-appliance
%dir /usr/libexec/grocery-pos-appliance
/usr/libexec/grocery-pos-appliance/configure-kiosk
/usr/libexec/grocery-pos-appliance/plasmalogin-grocery-pos.conf
/usr/libexec/grocery-pos-appliance/kscreenlockerrc
/usr/libexec/grocery-pos-appliance/powerdevilrc
/usr/lib/systemd/user/grocery-pos-terminal.service

%changelog
* Mon Sep 14 2026 Grocery POS Platform <internal@invalid> - 0.0.0-0.2.dev
- Require the POS Core authenticated-session API used by the kiosk terminal.

* Fri Sep 11 2026 Grocery POS Platform <internal@invalid> - 0.0.0-0.1.dev
- Establish the Fedora Kinoite kiosk provisioning and lifecycle boundary.
