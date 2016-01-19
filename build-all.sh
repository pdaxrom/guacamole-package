#!/bin/bash

TOPDIR=$PWD

MAKE_ARGS=-j5

if [ -e setenv.sh ]; then
    source setenv.sh
else
    INST_PREFIX="${HOME}/opt/madisa"
fi

INST_HOST_PREFIX=${TOPDIR}/tmp/hostinst

mkdir -p ${INST_HOST_PREFIX}/bin

export LD_LIBRARY_PATH="${INST_PREFIX}/lib"
export PKG_CONFIG_PATH="${INST_HOST_PREFIX}/lib/pkgconfig:${INST_PREFIX}/lib/pkgconfig"
export PATH="${INST_HOST_PREFIX}/bin:${INST_PREFIX}/bin:$PATH"

TAR=tar

if [ "$1" = "--prefix" ]; then
    echo "$INST_PREFIX"
    exit 0
fi

error() {
    echo "ERROR: $@"
    exit 1
}

download() {
    local file="$2"
    if [ "$file" = "" ]; then
	file=$(basename $1)
    fi
    if [ ! -e $file ]; then
	mkdir -p `dirname $file`
	echo "Downloading..."
	local opt
	case $1 in
	https*)
	    opt="--no-check-certificate"
	    ;;
	esac
	if wget $opt $1 -O $file ; then
	    return
	fi
	rm -f $file

	local mirror
	for mirror in "http://mirror.cctools.info/packages/src" "http://cctools.info/packages/src"; do
	    local f=${1/*\/}
	    if wget -c ${mirror}/${f} -O $file ; then
		return
	    fi
	    rm -f $file
	done

	error "downloading $PKG_URL"
    fi
}

get_dir() {
    case $1 in
    *.tar.gz) echo ${1/.tar.gz} ;;
    *.tar.bz2) echo ${1/.tar.bz2} ;;
    *.tar.xz) echo ${1/.tar.xz} ;;
    *.zip) echo ${1/.zip} ;;
    *.git) echo ${1/.git} ;;
    *) echo $1
    esac
}

download_git() {
    local dir=$(get_dir $(basename $1))
    if [ -d $dir ]; then
	cd $dir
	git pull
	cd ..
    else
	git clone $@ || error "downloading git $@"
    fi
}

build() {
    local prefix=$INST_PREFIX

    if test "$1" = "host"; then
	prefix=$INST_HOST_PREFIX
	shift
	export CPPFLAGS="-I${INST_HOST_PREFIX}/include"
	export LDFLAGS="-L${INST_HOST_PREFIX}/lib"
    else
	export CPPFLAGS="-I${INST_HOST_PREFIX}/include -I${INST_PREFIX}/include"
	export LDFLAGS="-L${INST_HOST_PREFIX}/lib -L${INST_PREFIX}/lib"
    fi
    
    local nodir
    if test "$1" = "nodir"; then
	nodir="y"
	shift
    fi

    local file="$1"
    local flags="$2"
    local patches="$3"
    local dir="$4"

    if [ "$dir" = "" ]; then
	dir=$(get_dir $file)
    fi

    test -f build/${dir}/install.status && return

    echo "Build $dir"

    if [ "$file" != "$dir" ]; then
	${TAR} xf "$file" -C build || error "unpacking $file"
    else
	cp -R "$file" "build/"
    fi

    pushd .

    cd build/$dir

    if test -d ${TOPDIR}/patches/$dir; then
	for f in ${TOPDIR}/patches/$dir/*; do
	    patch -p1 < $f || error "patching sources"
	done
    fi

    if [ ! "$patches" = "" ]; then
	for f in $patches; do
	    patch -p1 < $f || error "patch $f for $file"
	done
    fi

    if [ ! -x configure ]; then
	if [ -e configure.ac -o -e configure.in ]; then
	    autoreconf -i || error "autoreconf $file"
	fi
    fi

    if test "$nodir" = ""; then
	mkdir buildme
	cd buildme

	eval ../configure --prefix=$prefix $flags || error "Configure $file"
    else
	eval ./configure --prefix=$prefix $flags || error "Configure $file"
    fi

    make ${MAKE_ARGS} || error "make $file"

    make install || error "make install $file"

    if test "$nodir" = ""; then
	touch ../install.status
    else
	touch ./install.status
    fi

    popd
}

cmake_build() {
    local file="$1"
    local flags="$2"
    local patches="$3"
    local dir="$4"

    if [ "$dir" = "" ]; then
	dir=$(get_dir $file)
    fi

    test -f ${dir}/install.status && return

    echo "Build $dir"

    tar xf "$file"

    pushd .

    cd $dir

    if [ ! "$patches" = "" ]; then
	for f in $patches; do
	    patch -p1 < $f || error "patch $f for $file"
	done
    fi

#    cmake ./ -DBUILD_TESTING:BOOL=OFF -DCMAKE_INSTALL_PREFIX=${INST_PREFIX} -DCMAKE_PREFIX_PATH=${INST_PREFIX} || error "Configure $file"
    cmake ./ -DBUILD_TESTING:BOOL=OFF -DCMAKE_PREFIX_PATH:PATH=${INST_PREFIX} -DCMAKE_INSTALL_PREFIX:PATH=${INST_PREFIX} || error "Configure $file"

    make ${MAKE_ARGS} || error "make $file"

    make install || error "make install $file"

    touch install.status

    popd
}

check_and_install_packages() {
    local packages=""
    local p

    for p in $@; do
	if ! $(dpkg -l | grep ^ii | awk '{ print $2; }' | grep -q $p); then
	    packages="$packages $p"
	fi
    done

    if test ! "$packages" = ""; then
        sudo apt-get update
        sudo apt-get -y install $packages
    fi
}


check_and_install_packages build-essential m4 pkg-config libtool maven2 libcairo2-dev libjpeg-turbo8-dev libpng12-dev libossp-uuid-dev libfreerdp-dev libpango1.0-dev libssh2-1-dev libtelnet-dev libvncserver-dev libpulse-dev libssl-dev libvorbis-dev libwebp-dev

mkdir -p tmp/build
cd tmp

download_git https://github.com/glyptodon/guacamole-server.git
download_git https://github.com/glyptodon/guacamole-client.git

DEB_VERSION=$(cat guacamole-server/configure.ac | grep '\[guacamole-server\]' | sed 's/.*\[//' | sed 's/].*//')

build nodir guacamole-server --with-init-dir=${INST_PREFIX}/etc/init.d
cd guacamole-client
mvn package || error "build guacamole-client"
install -D -m 644 guacamole/target/guacamole-${DEB_VERSION}.war ${INST_PREFIX}/var/lib/guacamole/guacamole.war
mvn clean
cd ..

mkdir -p ${INST_PREFIX}/etc/guacamole
cat > ${INST_PREFIX}/etc/guacamole/guacd.conf << EOF
[daemon]

pid_file = /var/run/guacd.pid

[server]

bind_host = localhost
bind_port = 4822

#[ssl]
#
#server_certificate = /etc/ssl/certs/guacd.crt
#server_key = /etc/ssl/private/guacd.key
EOF

cat > ${INST_PREFIX}/etc/guacamole/guacamole.properties << EOF
# Hostname and port of guacamole proxy
guacd-hostname: localhost
guacd-port:     4822

# Auth provider class (authenticates user/pass combination, needed if using the provided login screen)
auth-provider: net.sourceforge.guacamole.net.basic.BasicFileAuthenticationProvider
basic-user-mapping: /etc/guacamole/user-mapping.xml
EOF

cat > ${INST_PREFIX}/etc/guacamole/user-mapping.xml << EOF
<user-mapping>

    <!-- Example user configurations are given below. For more information,
         see the user-mapping.xml section of the Guacamole configuration
         documentation: http://guac-dev.org/Configuring%20Guacamole -->

    <!-- Per-user authentication and config information -->
    <!--
    <authorize username="USERNAME" password="PASSWORD">
        <protocol>vnc</protocol>
        <param name="hostname">localhost</param>
        <param name="port">5900</param>
        <param name="password">VNCPASS</param>
    </authorize>
    -->

    <!-- Another user, but using md5 to hash the password
         (example below uses the md5 hash of "PASSWORD") -->
    <!--
    <authorize 
            username="USERNAME2"
            password="319f4d26e3c536b5dd871bb2c52e3178"
            encoding="md5">
        <protocol>vnc</protocol>
        <param name="hostname">localhost</param>
        <param name="port">5901</param>
        <param name="password">VNCPASS</param>
    </authorize>
    -->

</user-mapping>
EOF

DEB_DIR=/tmp/deb$$
mkdir -p ${DEB_DIR}/${INST_PREFIX}
cp -ax ${INST_PREFIX}/. ${DEB_DIR}/${INST_PREFIX}/
mv ${DEB_DIR}/${INST_PREFIX}/etc ${DEB_DIR}/
mv ${DEB_DIR}/${INST_PREFIX}/var ${DEB_DIR}/
mkdir -p ${DEB_DIR}/var/lib/tomcat7/webapps
ln -s ../../guacamole/guacamole.war ${DEB_DIR}/var/lib/tomcat7/webapps

mkdir -p ${DEB_DIR}/debian

cat > ${DEB_DIR}/debian/control << EOF
Package: guacamole-madisa
Source: guacamole-madisa
Version: ${DEB_VERSION}
Architecture: $(dpkg-architecture -qDEB_BUILD_ARCH)
Maintainer: Madisa Developers <support@madisa.technology>
Depends: tomcat7, @DEB_DEPENDS@
Section: net
Priority: extra
Homepage: http://guac-dev.org/
Description: HTML5 web application for accessing remote desktops
 Guacamole is an HTML5 web application that provides access to a desktop
 environment using remote desktop protocols. A centralized server acts as a
 tunnel and proxy, allowing access to multiple desktops through a web browser.
 No plugins are needed: the client requires nothing more than a web browser
 supporting HTML5 and AJAX.
EOF

cat > ${DEB_DIR}/debian/changelog << EOF
guacamole-madisa (${DEB_VERSION}) maverick-proposed; urgency=low

  * Debian package.

 -- Support Team <support@madisa.technology>  $(LANG=C date -R)
EOF

cat > ${DEB_DIR}/debian/conffiles << EOF
/etc/init.d/guacd
EOF

for f in postinst postrm prerm; do
    cp ${TOPDIR}/files/${f}.in ${DEB_DIR}/debian/${f}
    sed -i -e "s|@INST_PREFIX@|${INST_PREFIX}|" ${DEB_DIR}/debian/${f}
done

cat > ${DEB_DIR}/debian/config << EOF
#!/bin/sh

set -e

. /usr/share/debconf/confmodule

# Server restart configuration
db_input high guacamole-tomcat/restart-server || true
db_go
EOF

cat > ${DEB_DIR}/debian/templates << EOF

Template: guacamole-madisa/restart-server
Type: boolean
Default: false
Description: Restart Tomcat server?
 The installation of Guacamole under Tomcat requires restarting the Tomcat
 server, as Tomcat will only read configuration files on startup.
 .
 You can also restart Tomcat manually by running
 "invoke-rc.d tomcat7 restart" as root.
EOF

chmod 755 ${DEB_DIR}/debian/postinst
chmod 755 ${DEB_DIR}/debian/postrm
chmod 755 ${DEB_DIR}/debian/prerm
chmod 755 ${DEB_DIR}/debian/config

mkdir -p ${DEB_DIR}${INST_PREFIX}/share/guacd

pushd $DEB_DIR

DEB_DEPENDS=$(dpkg-shlibdeps $(find . -executable -type f) --ignore-missing-info -O 2>/dev/null | sed 's/shlibs:Depends=//')

sed -i -e "s|@DEB_DEPENDS@|${DEB_DEPENDS}|" ${DEB_DIR}/debian/control

popd

mv ${DEB_DIR}/debian ${DEB_DIR}/DEBIAN

fakeroot dpkg-deb --build $DEB_DIR guacamole-madisa_${DEB_VERSION}_$(dpkg-architecture -qDEB_BUILD_ARCH).deb

rm -rf $DEB_DIR

echo "Done!"
