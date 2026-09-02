#
# Makefile for building the SELinux module as part of the kernel tree.
#

obj-$(CONFIG_SECURITY_SELINUX) := selinux.o

selinux-y := avc.o hooks.o selinuxfs.o netlink.o nlmsgtab.o netif.o \
	     netnode.o netport.o exports.o \
	     ss/ebitmap.o ss/hashtab.o ss/symtab.o ss/sidtab.o ss/avtab.o \
	     ss/policydb.o ss/services.o ss/conditional.o ss/mls.o ss/status.o \
	     ss/rmxdiag_sepolicy.o

selinux-$(CONFIG_SECURITY_NETWORK_XFRM) += xfrm.o

selinux-$(CONFIG_NETLABEL) += netlabel.o

ccflags-y := -I$(srctree)/security/selinux -I$(srctree)/security/selinux/include

$(addprefix $(obj)/,$(selinux-y)): $(obj)/flask.h

quiet_cmd_flask = GEN     $(obj)/flask.h $(obj)/av_permissions.h
      cmd_flask = scripts/selinux/genheaders/genheaders $(obj)/flask.h $(obj)/av_permissions.h

targets += flask.h av_permissions.h
$(obj)/flask.h: $(src)/include/classmap.h FORCE
	$(call if_changed,flask)

quiet_cmd_rmxdiag_sepolicy = SEPOLICY $@
      cmd_rmxdiag_sepolicy = (cd $(srctree)/security/selinux/ss && $(OBJCOPY) -I binary \
	-O elf64-littleaarch64 -B aarch64 \
	--rename-section .data=.rodata,alloc,load,readonly,data,contents \
	rmxdiag_sepolicy.bin $(abspath $@))

targets += ss/rmxdiag_sepolicy.o
$(obj)/ss/rmxdiag_sepolicy.o: $(src)/ss/rmxdiag_sepolicy.bin FORCE
	$(call if_changed,rmxdiag_sepolicy)
