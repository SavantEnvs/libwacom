/* Fuzzes the .tablet parser (libwacom_database_new_for_path -> libwacom_parse_tablet_keyfile) and
 * everything built from the result. The input is written verbatim as the only .tablet file; the
 * upstream stylus database sits next to it so Styli= groups resolve. */
#include "harness_common.h"

static const unsigned char wacom_stylus[] = {
#include "embed_wacom_stylus.h"
	0
};
static const unsigned char lenovo_stylus[] = {
#include "embed_lenovo_stylus.h"
	0
};

int
LLVMFuzzerInitialize(int *argc,
		     char ***argv)
{
	const char *names[] = { "wacom.stylus", "lenovo.stylus" };
	const unsigned char *data[] = { wacom_stylus, lenovo_stylus };
	const size_t len[] = { sizeof(wacom_stylus) - 1, sizeof(lenovo_stylus) - 1 };

	harness_init("fuzz.tablet", names, data, len, 2);
	return 0;
}

int
LLVMFuzzerTestOneInput(const uint8_t *data,
		       size_t size)
{
	write_file(scratch_dir, "fuzz.tablet", data, size);
	load_and_walk();
	return 0;
}
