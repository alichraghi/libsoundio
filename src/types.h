union snd_pcm_sync_id {
  unsigned char id[16];
  unsigned short id16[8];
  unsigned int id32[4];
};

struct snd_pcm_info {
  unsigned int device;       /* RO/WR (control): device number */
  unsigned int subdevice;    /* RO/WR (control): subdevice number */
  int stream;                /* RO/WR (control): stream direction */
  int card;                  /* R: card number */
  unsigned char id[64];      /* ID (user selectable) */
  unsigned char name[80];    /* name of this device */
  unsigned char subname[32]; /* subdevice name */
  int dev_class;             /* SNDRV_PCM_CLASS_* */
  int dev_subclass;          /* SNDRV_PCM_SUBCLASS_* */
  unsigned int subdevices_count;
  unsigned int subdevices_avail;
  union snd_pcm_sync_id sync; /* hardware synchronization ID */
  unsigned char reserved[64]; /* reserved for future... */
};

struct snd_ctl_card_info {
  int card;                      /* card number */
  int pad;                       /* reserved for future (was type) */
  unsigned char id[16];          /* ID of card (user selectable) */
  unsigned char driver[16];      /* Driver name */
  unsigned char name[32];        /* Short name of soundcard */
  unsigned char longname[80];    /* name + info text about soundcard */
  unsigned char reserved_[16];   /* reserved for future (was ID of mixer) */
  unsigned char mixername[80];   /* visual mixer identification */
  unsigned char components[128]; /* card components / fine identification,
                                    delimited with one space (AC97 etc..) */
};