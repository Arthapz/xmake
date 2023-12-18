# this is a SRPM spec file,
# it is autogenerated by the xmake build system.
# do not edit by hand.

%global     debug_package %{nil}

Name:       ${PACKAGE_NAME}
Version:    ${PACKAGE_VERSION}
Release:    1%{?dist}
Summary:    ${PACKAGE_TITLE}

License:    ${PACKAGE_LICENSE}
URL:        ${PACKAGE_HOMEPAGE}
Source0:    ${PACKAGE_ARCHIVEFILE}

BuildRequires: gcc
BuildRequires: gcc-c++

%description
${PACKAGE_DESCRIPTION}

%prep
%autosetup -n ${PACKAGE_PREFIXDIR} -p1

%build

%install
${PACKAGE_INSTALLCMDS}
cd %{buildroot}
find . -type f | sed 's!^\./!/!' > %{_builddir}/_installedfiles.txt

%check

%files -f %{_builddir}/_installedfiles.txt

%changelog
* ${PACKAGE_DATE} ${PACKAGE_MAINTAINER} - ${PACKAGE_VERSION}-1
- Update to ${PACKAGE_VERSION}

