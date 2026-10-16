Name:           osmanthus-release
Version:        1
Release:        1%{?dist}
Summary:        DNF repository configuration for Osmanthus
License:        MIT
URL:            https://github.com/ttr1563/osmanthus-shell
Source0:        osmanthus.repo
Source1:        RPM-GPG-KEY-OSMANTHUS
BuildArch:      noarch

%description
Repository configuration and public package-signing key for the Osmanthus DNF
repository on Amazon Linux 2023.

%prep

%build

%install
install -Dpm0644 %{SOURCE0} %{buildroot}%{_sysconfdir}/yum.repos.d/osmanthus.repo
install -Dpm0644 %{SOURCE1} %{buildroot}%{_sysconfdir}/pki/rpm-gpg/RPM-GPG-KEY-OSMANTHUS

%files
%config(noreplace) %{_sysconfdir}/yum.repos.d/osmanthus.repo
%{_sysconfdir}/pki/rpm-gpg/RPM-GPG-KEY-OSMANTHUS

%changelog
* Fri Oct 16 2026 Osmanthus maintainers <ttr1563@users.noreply.github.com> - 1-1
- Add the initial Osmanthus repository configuration and signing key.
