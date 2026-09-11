Name:           grocery-pos-core
Version:        0.0.0
Release:        0.1.dev%{?dist}
Summary:        Local-first Grocery POS transaction core
License:        LicenseRef-Project-Undecided
URL:            https://github.com/adarj/grocery-pos-platform
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch
Requires:       racket

%description
Grocery POS Core is the local Racket authority for transaction, catalog,
tax, receipt, register, shift, and cash-accountability semantics. This internal
package installs the source application and its Fedora systemd service boundary.

%prep
%autosetup

%build
# The application is architecture-independent Racket source. Fedora supplies
# the runtime; no source compilation or Nix-built runtime is packaged.

%install
install -d %{buildroot}/usr/libexec/grocery-pos-core
install -m 0644 main.rkt %{buildroot}/usr/libexec/grocery-pos-core/main.rkt
cp -a pos %{buildroot}/usr/libexec/grocery-pos-core/pos
cp -a scripts %{buildroot}/usr/libexec/grocery-pos-core/scripts
find %{buildroot}/usr/libexec/grocery-pos-core/pos \
  %{buildroot}/usr/libexec/grocery-pos-core/scripts \
  -type f -exec chmod 0644 {} +

install -m 0755 packaging/fedora/run-pos-core \
  %{buildroot}/usr/libexec/grocery-pos-core/run-pos-core
install -D -m 0755 packaging/fedora/grocery-pos-db \
  %{buildroot}/usr/bin/grocery-pos-db
install -D -m 0755 packaging/fedora/grocery-pos-catalog \
  %{buildroot}/usr/bin/grocery-pos-catalog
install -D -m 0755 packaging/fedora/grocery-pos-register-config \
  %{buildroot}/usr/bin/grocery-pos-register-config

install -D -m 0644 packaging/fedora/grocery-pos-core.service \
  %{buildroot}/usr/lib/systemd/system/grocery-pos-core.service
install -D -m 0644 packaging/fedora/grocery-pos-core.sysusers \
  %{buildroot}/usr/lib/sysusers.d/grocery-pos.conf
install -D -m 0644 packaging/fedora/pos-core.env \
  %{buildroot}/etc/grocery-pos/pos-core.env

%files
%defattr(-,root,root,-)
%dir /usr/libexec/grocery-pos-core
/usr/libexec/grocery-pos-core/main.rkt
/usr/libexec/grocery-pos-core/pos
/usr/libexec/grocery-pos-core/scripts
/usr/libexec/grocery-pos-core/run-pos-core
/usr/bin/grocery-pos-db
/usr/bin/grocery-pos-catalog
/usr/bin/grocery-pos-register-config
/usr/lib/systemd/system/grocery-pos-core.service
/usr/lib/sysusers.d/grocery-pos.conf
%dir /etc/grocery-pos
%config(noreplace) /etc/grocery-pos/pos-core.env

%changelog
* Thu Sep 10 2026 Grocery POS Platform <internal@invalid> - 0.0.0-0.1.dev
- Establish the initial internal Fedora-native POS Core service package.
