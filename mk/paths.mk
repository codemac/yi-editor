################################################################################
#
#			    paths.mk
#
# 	This file defines Make variables for standard directories
#	and file lists
#
################################################################################

#
#
#		Standard variable names
#
#
# The fptools mk setup defines a set of standard names which are used
# by the standard targets provided by mk. One example of this is the
# use of standard names for specifying what files to compile, their
# intermediate/object code, and the name of the final
# executable. Based on the settings of these variables, the standard
# targets will generate/expand rules that automatically compile and
# link your program.
#
# The general rules:
#
#   SRCS - sources, might be prefixed to indicate what type of source
#          they are.
#   OBJS - object files (possibly prefixed).
#
#   PROG - name of final executable
#
# We attempt to automatically devine the list of sources $(SRCS) to
# compile by looking in the directories which may be specified by
# setting the $(ALL_DIRS) variable.  This is complicated by the fact
# that some files are derived from other files: eg. .hsc files give
# rise to -hsc.c and -hsc.h files, .ly files give rise to .hs files,
# and .hs files give rise to .hc files sometimes.

# So we figure out the sources in three stages: first figure out what
# sources we can find (this is $(ALL_SRCS)).  Then figure out all the
# "derived" sources (eg. A.hsc generates A.hs and A_hsc.c), and
# finally put all these together and remove duplicates (GNU make's
# handy sort function does the duplicate removing).

# HS_SRCS:   list of Haskell modules you want to compile.
#             (also use by depend rule).
# HS_OBJS:   list of corresponding object files
# HS_PROG:   program that is ultimately linked.
# HS_IFACES: list of interface files generated
#             (caveat: assuming no funny use of -hisuf and that
#               file name and module name match)

ALL_SRCS    = $(wildcard $(patsubst ./%, %,  \
		   $(patsubst %,%/*.hs,   $(ALL_DIRS)) \
		   $(patsubst %,%/*.lhs,  $(ALL_DIRS)) \
		   $(patsubst %,%/*.y,    $(ALL_DIRS)) \
		   $(patsubst %,%/*.ly,   $(ALL_DIRS)) \
		   $(patsubst %,%/*.x,    $(ALL_DIRS)) \
		   $(patsubst %,%/*.c,    $(ALL_DIRS)) \
		   $(patsubst %,%/*.hc,   $(ALL_DIRS)) \
		   $(patsubst %,%/*.S,    $(ALL_DIRS)) \
		   $(patsubst %,%/*.prl,  $(ALL_DIRS)) \
		   $(patsubst %,%/*.lprl, $(ALL_DIRS)) \
		   $(patsubst %,%/*.lit,  $(ALL_DIRS)) \
		   $(patsubst %,%/*.verb, $(ALL_DIRS)) \
		   $(patsubst %,%/*.hsc,  $(ALL_DIRS)) \
		   $(patsubst %,%/*.gc,   $(ALL_DIRS)) \
	       )) $(EXTRA_SRCS)

# ALL_SRCS is computed once and for all into PRE_SRCS at the top of
# rules.mk.  Otherwise, we end up re-computing ALL_SRCS every time it
# is expanded (it is used in several variables below, and these
# variables are used in several others, etc.), which can really slow
# down make.

PRE_HS_SRCS  = $(filter %.hs,  $(PRE_SRCS))
PRE_LHS_SRCS = $(filter %.lhs, $(PRE_SRCS))

GC_SRCS       = $(filter %.gc,  $(PRE_SRCS))
HSC_SRCS      = $(filter %.hsc, $(PRE_SRCS))
HAPPY_Y_SRCS  = $(filter %.y,   $(PRE_SRCS))
HAPPY_LY_SRCS = $(filter %.ly,   $(PRE_SRCS))
HAPPY_SRCS    = $(HAPPY_Y_SRCS) $(HAPPY_LY_SRCS)
ALEX_SRCS     = $(filter %.x,   $(PRE_SRCS))

DERIVED_GC_SRCS       = $(patsubst %.gc, %.hs, $(GC_SRCS)) \
			$(patsubst %.gc, %_stub_ffi.c, $(GC_SRCS)) \
			$(patsubst %.gc, %_stub_ffi.h, $(GC_SRCS))

DERIVED_HSC_SRCS      = $(patsubst %.hsc, %.hs, $(HSC_SRCS)) \
			$(patsubst %.hsc, %_hsc.c, $(HSC_SRCS)) \
			$(patsubst %.hsc, %_hsc.h, $(HSC_SRCS)) \
			$(patsubst %.hsc, %.hc, $(HSC_SRCS))

DERIVED_HAPPY_SRCS    = $(patsubst %.y,   %.hs, $(HAPPY_Y_SRCS)) \
			$(patsubst %.ly,  %.hs, $(HAPPY_LY_SRCS))

DERIVED_ALEX_SRCS     = $(patsubst %.x,   %.hs, $(ALEX_SRCS))

DERIVED_HC_SRCS       = $(patsubst %.hs,  %.hc, $(PRE_HS_SRCS)) \
			$(patsubst %.lhs, %.hc, $(PRE_LHS_SRCS))

DERIVED_SRCS	      = $(DERIVED_GC_SRCS) \
			$(DERIVED_HSC_SRCS) \
			$(DERIVED_HAPPY_SRCS) \
			$(DERIVED_ALEX_SRCS) \
			$(DERIVED_HC_SRCS)

# EXCLUDED_SRCS can be set in the Makefile, otherwise it defaults to empty.
EXCLUDED_GC_SRCS       = $(filter %.gc,  $(EXCLUDED_SRCS))
EXCLUDED_HSC_SRCS      = $(filter %.hsc, $(EXCLUDED_SRCS))
EXCLUDED_HAPPY_Y_SRCS  = $(filter %.y,   $(EXCLUDED_SRCS))
EXCLUDED_HAPPY_LY_SRCS = $(filter %.ly,  $(EXCLUDED_SRCS))
EXCLUDED_HAPPY_SRCS   = $(EXCLUDED_HAPPY_Y_SRCS) $(EXCLUDED_HAPPY_LY_SRCS)
EXCLUDED_ALEX_SRCS    = $(filter %.x,   $(EXCLUDED_SRCS))
EXCLUDED_HS_SRCS      = $(filter %.hs,  $(EXCLUDED_SRCS))
EXCLUDED_LHS_SRCS     = $(filter %.lhs, $(EXCLUDED_SRCS))
EXCLUDED_DERIVED_SRCS = $(patsubst %.hsc, %.hs, $(EXCLUDED_HSC_SRCS)) \
			$(patsubst %.hsc, %_hsc.h, $(EXCLUDED_HSC_SRCS)) \
			$(patsubst %.hsc, %_hsc.c, $(EXCLUDED_HSC_SRCS)) \
			$(patsubst %.hsc, %.hc, $(EXCLUDED_HSC_SRCS)) \
			$(patsubst %.gc,  %_stub_ffi.c, $(EXCLUDED_GC_SRCS)) \
			$(patsubst %.gc,  %_stub_ffi.h, $(EXCLUDED_GC_SRCS)) \
                        $(patsubst %.y,   %.hs, $(EXCLUDED_HAPPY_Y_SRCS)) \
			$(patsubst %.ly,  %.hs, $(EXCLUDED_HAPPY_LY_SRCS)) \
                        $(patsubst %.x,   %.hs, $(EXCLUDED_ALEX_SRCS)) \
			$(patsubst %.hs,  %.hc, $(EXCLUDED_HS_SRCS)) \
			$(patsubst %.lhs, %.hc, $(EXCLUDED_LHS_SRCS)) \
			$(patsubst %.hs,  %_stub.c, $(EXCLUDED_HS_SRCS)) \
			$(patsubst %.lhs, %_stub.c, $(EXCLUDED_LHS_SRCS))

# Exclude _hsc.c files; they get built as part of the cbits library,
# not part of the main library

CLOSED_EXCLUDED_SRCS  = $(sort $(EXCLUDED_SRCS) $(EXCLUDED_DERIVED_SRCS))

SRCS        = $(filter-out $(CLOSED_EXCLUDED_SRCS), \
	        $(sort $(PRE_SRCS) $(DERIVED_SRCS)))

HS_SRCS	    = $(filter %.lhs %.hs, $(sort $(SRCS) $(BOOT_SRCS)))
HS_OBJS     = $(addsuffix .$(way_)o,$(basename $(HS_SRCS)))
HS_IFACES   = $(addsuffix .$(way_)hi,$(basename $(HS_SRCS)))

GC_C_OBJS   = $(addsuffix _stub_ffi.$(way_)o,$(basename $(filter %.gc,$(SRCS))))
HSC_C_OBJS  = $(addsuffix _hsc.$(way_)o,$(basename $(filter %.hsc,$(SRCS))))

# These are droppings from hsc2hs - ignore them if we see them.
EXCLUDED_C_SRCS += $(patsubst %.hsc, %_hsc_make.c, $(HSC_SRCS))

C_SRCS      = $(filter-out $(EXCLUDED_C_SRCS),$(filter %.c,$(SRCS)))
C_OBJS      = $(addsuffix .$(way_)o,$(basename $(C_SRCS)))

# SCRIPT_SRCS:  list of raw script files (in literate form)
# SCRIPT_OBJS:  de-litted scripts
SCRIPT_SRCS = $(filter %.lprl,$(SRCS))
SCRIPT_OBJS = $(addsuffix .prl,$(basename $(SCRIPT_SRCS)))

OBJS        = $(HS_OBJS) $(C_OBJS) $(GC_C_OBJS) 

# The default is for $(LIBOBJS) to be the same as $(OBJS)
LIBOBJS	    = $(OBJS)

#
# Note that as long as you use the standard variables for setting
# which C & Haskell programs you want to work on, you don't have
# to set any of the clean variables - the default should do the Right
# Thing.
#

#------------------------------------------------------------------
#
# make depend defaults
#
# The default set of files for the dependency generators to work on
# is just their source equivalents.
#

MKDEPENDHS_SRCS=$(HS_SRCS)
MKDEPENDC_SRCS=$(C_SRCS)

#------------------------------------------------------------------
# Clean file make-variables.
#
# The following three variables are used to control
# what gets removed when doing `make clean'
#
# MOSTLYCLEAN_FILES   object code etc., but not stuff
#                     that is slow to recompile and/or stable
#
# CLEAN_FILES  all files that are created by running make.
#
# MAINTAINER_CLEAN_FILES also clean out machine-generated files
#                        that may require extra tools to create.
#
#
# NOTE: $(SCRIPT_OBJS) is not in MOSTLY_CLEAN_FILES, because in some
# places in the tree it appears that we have source files in $(SCRIPT_OBJS).
# Specifically glafp-utils/mkdependC/mkdependC.prl and others in ghc/driver and
# possibly others elsewhere in the tree.  ToDo: fix this properly.
MOSTLY_CLEAN_FILES += $(HS_OBJS) $(C_OBJS) $(HSC_C_OBJS) $(GC_C_OBJS)
CLEAN_FILES        += $(HS_PROG) $(C_PROG) $(SCRIPT_PROG) $(SCRIPT_LINK) \
		      $(PROG) $(LIBRARY) a.out \
		      $(DERIVED_HSC_SRCS) \
		      $(DERIVED_GC_SRCS) \
		      $(patsubst %,%/*.$(way_)hi, . $(ALL_DIRS)) \
		      $(patsubst %,%/*.p_hi, . $(ALL_DIRS)) \
		      $(patsubst %,%/*.p_o, . $(ALL_DIRS))

# we delete *all* the .hi files we can find, rather than just
# $(HS_IFACES), because stale interfaces left around by modules which
# don't exist any more can screw up the build.

# Don't clean the .hc files if we're bootstrapping
CLEAN_FILES += $(DERIVED_HC_SRCS)

DIST_CLEAN_FILES 	+= depend* *.hp *.prof configure mk/config.h* mk/config.mk
DIST_CLEAN_DIRS=  *.cache

MAINTAINER_CLEAN_FILES 	+= $(BOOT_SRCS) $(DERIVED_HAPPY_SRCS) $(DERIVED_ALEX_SRCS)

#
# `Standard' set of files to clean out.
#
MOSTLY_CLEAN_FILES += \
 *.CKP *.ln *.BAK *.bak .*.bak *.o *.p_o core a.out errs ,* *.a .emacs_*  \
 tags TAGS *.ind *.ilg *.idx *.idx-prev *.aux *.aux-prev *.dvi *.log \
 *.toc *.lot *.lof *.blg *.cb *_stub.c *_stub.h *.raw_s *.a.list \
 *.log *.status

