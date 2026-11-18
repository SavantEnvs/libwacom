/* Shared by the libwacom harnesses: stage one fuzzed file into a scratch directory that also holds a
 * fixed, valid file of the other kind, load the database through the public API, then walk it. */
#include <fcntl.h>
#include <glib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "libwacom.h"

static char scratch_dir[4096];
static char fuzz_path[4400];
static int sink_fd = -1;

static void
quiet_log(const gchar *domain,
	  GLogLevelFlags level,
	  const gchar *message,
	  gpointer data)
{
}

static void
write_file(const char *dir,
	   const char *name,
	   const unsigned char *data,
	   size_t len)
{
	char path[4400];
	FILE *f;

	snprintf(path, sizeof(path), "%s/%s", dir, name);
	f = fopen(path, "wb");
	if (!f)
		abort();
	if (len && fwrite(data, 1, len, f) != len)
		abort();
	fclose(f);
}

/* fuzz_name is the file the fuzzer controls; the fixed files make the database loadable at all
 * (libwacom refuses a database without at least one tablet and one stylus). */
static void
harness_init(const char *fuzz_name,
	     const char *const *fixed_names,
	     const unsigned char *const *fixed_data,
	     const size_t *fixed_len,
	     size_t nfixed)
{
	const char *tmp = getenv("TMPDIR");
	char tmpl[4096];

	if (!tmp || !*tmp)
		tmp = "/tmp";
	snprintf(tmpl, sizeof(tmpl), "%s/libwacom-fuzz-XXXXXX", tmp);
	if (!mkdtemp(tmpl))
		abort();
	snprintf(scratch_dir, sizeof(scratch_dir), "%s", tmpl);
	snprintf(fuzz_path, sizeof(fuzz_path), "%s/%s", scratch_dir, fuzz_name);

	for (size_t i = 0; i < nfixed; i++)
		write_file(scratch_dir, fixed_names[i], fixed_data[i], fixed_len[i]);

	sink_fd = open("/dev/null", O_WRONLY);
	if (sink_fd < 0)
		abort();
	g_log_set_default_handler(quiet_log, NULL);
}

static void
walk_stylus(const WacomStylus *s)
{
	int n = 0;
	const WacomStylus **paired;

	libwacom_print_stylus_description(sink_fd, s);
	(void)libwacom_stylus_get_id(s);
	(void)libwacom_stylus_get_vendor_id(s);
	(void)libwacom_stylus_get_name(s);
	(void)libwacom_stylus_get_num_buttons(s);
	(void)libwacom_stylus_has_eraser(s);
	(void)libwacom_stylus_is_eraser(s);
	(void)libwacom_stylus_is_generic(s);
	(void)libwacom_stylus_has_lens(s);
	(void)libwacom_stylus_has_wheel(s);
	(void)libwacom_stylus_get_axes(s);
	(void)libwacom_stylus_get_type(s);
	(void)libwacom_stylus_get_eraser_type(s);
	paired = libwacom_stylus_get_paired_styli(s, &n);
	for (int i = 0; paired && paired[i]; i++)
		(void)libwacom_stylus_get_name(paired[i]);
	free(paired);
}

static void
walk_device(const WacomDeviceDatabase *db,
	    const WacomDevice *d)
{
	int n = 0;
	const WacomMatch **matches;
	const WacomStylus **styli;
	WacomDevice *again;

	libwacom_print_device_description(sink_fd, d);

	(void)libwacom_get_name(d);
	(void)libwacom_get_model_name(d);
	(void)libwacom_get_layout_filename(d);
	(void)libwacom_get_match(d);
	(void)libwacom_get_width(d);
	(void)libwacom_get_height(d);
	(void)libwacom_get_width_mm(d);
	(void)libwacom_get_height_mm(d);
	(void)libwacom_has_stylus(d);
	(void)libwacom_has_touch(d);
	(void)libwacom_get_num_rings(d);
	(void)libwacom_has_touchswitch(d);
	(void)libwacom_get_ring_num_modes(d);
	(void)libwacom_get_ring2_num_modes(d);
	(void)libwacom_get_num_strips(d);
	(void)libwacom_get_strips_num_modes(d);
	(void)libwacom_get_num_dials(d);
	(void)libwacom_get_dial_num_modes(d);
	(void)libwacom_get_dial2_num_modes(d);
	(void)libwacom_is_reversible(d);
	(void)libwacom_get_integration_flags(d);
	(void)libwacom_get_paired_device(d);
	(void)libwacom_get_num_keys(d);
	(void)libwacom_get_status_leds(d, &n);

	n = libwacom_get_num_buttons(d);
	for (int i = 0; i < n && i < 26; i++) {
		char b = 'A' + i;
		(void)libwacom_get_button_flag(d, b);
		(void)libwacom_get_button_evdev_code(d, b);
		(void)libwacom_get_button_led_group(d, b);
		(void)libwacom_get_button_modeswitch_mode(d, b);
	}

	matches = libwacom_get_matches(d);
	for (int i = 0; matches && matches[i]; i++) {
		(void)libwacom_match_get_name(matches[i]);
		(void)libwacom_match_get_uniq(matches[i]);
		(void)libwacom_match_get_bustype(matches[i]);
		(void)libwacom_match_get_vendor_id(matches[i]);
		(void)libwacom_match_get_product_id(matches[i]);
		(void)libwacom_match_get_match_string(matches[i]);
	}

	styli = libwacom_get_styli(d, &n);
	for (int i = 0; styli && styli[i]; i++)
		walk_stylus(styli[i]);
	free(styli);

	/* Look the device up again the way a client does. */
	again = libwacom_new_from_usbid(db,
					libwacom_get_vendor_id(d),
					libwacom_get_product_id(d),
					NULL);
	if (again) {
		(void)libwacom_compare(d, again, WCOMPARE_NORMAL);
		libwacom_destroy(again);
	}
	if (libwacom_get_name(d)) {
		again = libwacom_new_from_name(db, libwacom_get_name(d), NULL);
		if (again)
			libwacom_destroy(again);
	}
}

/* Load the scratch directory and walk everything the parsers produced. */
static void
load_and_walk(void)
{
	WacomDeviceDatabase *db = libwacom_database_new_for_path(scratch_dir);
	WacomDevice **devices;
	const WacomStylus **styli;

	if (!db)
		return;

	devices = libwacom_list_devices_from_database(db, NULL);
	for (int i = 0; devices && devices[i]; i++)
		walk_device(db, devices[i]);
	free(devices);

	styli = libwacom_list_styli_from_database(db, NULL);
	for (int i = 0; styli && styli[i]; i++) {
		walk_stylus(styli[i]);
		(void)libwacom_stylus_get_for_id(db, libwacom_stylus_get_id(styli[i]));
	}
	free(styli);

	libwacom_database_destroy(db);
}
