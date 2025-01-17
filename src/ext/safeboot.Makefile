HCP_SAFEBOOT_SRC := $(TOP)/ext-safeboot
HCP_SAFEBOOT_INSTALL_DEST := /install-safeboot

# We steal the TPMWARE settings as to whether or not enable the
# SUBMODULE_{RESET,TARGETS} options
$(eval $(call builder_initialize,\
	safeboot,\
	$(HCP_SAFEBOOT_SRC),\
	$(HCP_SAFEBOOT_INSTALL_DEST),\
	$(HCP_TPMWARE_SUBMODULE_RESET),\
	$(HCP_TPMWARE_SUBMODULE_TARGETS)))

# Before adding the build/install rules for safeboot, build up the command-line
# that will add the missing symlink and install the files.
$(eval SAFEBOOT_INSTALL_CMD := mkdir -p $(HCP_SAFEBOOT_INSTALL_DEST)/sbin ;)
$(eval SAFEBOOT_INSTALL_CMD += (cd $(HCP_SAFEBOOT_INSTALL_DEST)/sbin && rm -f attest_server.py && ln -s attest-server attest_server.py) ;)
# $1 = destination path relative to /install-safeboot, no leading nor trailing "/"
# $2 = source path, relative to codebase top-level, no leading "/"
# $3 = attributes (first arg to "chmod")
# $4 = file names
define add_safeboot_install
$(eval LOCAL_INSTPATH := $(strip $1))
$(eval LOCAL_SRCPATH := $(strip $2))
$(eval LOCAL_ATTRS := $(strip $3))
$(eval LOCAL_FILES := $(strip $4))
$(eval SAFEBOOT_INSTALL_CMD += mkdir -p $(HCP_SAFEBOOT_INSTALL_DEST)/$(LOCAL_INSTPATH) ;)
$(eval SAFEBOOT_INSTALL_CMD += (cd $(LOCAL_SRCPATH) ; cp $(LOCAL_FILES) $(HCP_SAFEBOOT_INSTALL_DEST)/$(LOCAL_INSTPATH)/) ;)
$(eval SAFEBOOT_INSTALL_CMD += (cd $(HCP_SAFEBOOT_INSTALL_DEST)/$(LOCAL_INSTPATH) ; chmod $(LOCAL_ATTRS) $(LOCAL_FILES)) ;)
$(eval SAFEBOOT_DEP_FILES += $(foreach i,$(LOCAL_FILES),$(HCP_SAFEBOOT_SRC)/$2/$i))
endef
$(eval $(call add_safeboot_install,\
		.,.,644,\
		functions.sh safeboot.conf))
$(eval $(call add_safeboot_install,\
		sbin,sbin,755,\
		$(shell ls -1 $(HCP_SAFEBOOT_SRC)/sbin)))
$(eval $(call add_safeboot_install,\
		tests,tests,755,\
		$(shell ls -1 $(HCP_SAFEBOOT_SRC)/tests)))
# TODO: remove these?
$(eval $(call add_safeboot_install,\
		initramfs,initramfs,755,\
		bootscript \
		busybox.config \
		cmdline.txt \
		config.sh \
		dev.cpio \
		files.txt \
		init \
		linux.config \
		udhcpc.sh))

# Now add the 'safeboot' codebase to the package. We only implement the
# "install" hook, to patch in the necessary "attest_server.py"->"attest-server"
# symlink and put the relevant files into their installation destination.
$(eval $(call builder_add_codebase,\
	safeboot,\
	safeboot,\
	,\
	.,\
	functions.sh,\
	true,\
	true,\
	true,\
	$(SAFEBOOT_INSTALL_CMD)))

# The add_codebase() defines some symbols we can use to hook dependencies in!
$(HCP_BUILD_DEP_safeboot_safeboot_INSTALLED): $(SAFEBOOT_DEP_FILES)

# Thus concludes the "safeboot" package
$(eval $(call builder_finalize,safeboot))
