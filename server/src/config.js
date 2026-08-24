require('dotenv').config();

const path = require('path');

const DATA_DIR = process.env.DATA_DIR
  ? path.resolve(process.env.DATA_DIR)
  : path.resolve(__dirname, '..', 'data');

const config = {
  PORT: parseInt(process.env.PORT || '8877', 10),
  HOST: process.env.HOST || '0.0.0.0',
  DATA_DIR,
  UPLOAD_DIR: path.join(DATA_DIR, 'uploads'),
  CACHE_DIR: path.join(DATA_DIR, 'cache'),
  ADB_KEY_DIR: process.env.ADB_KEY_DIR
    ? path.resolve(process.env.ADB_KEY_DIR)
    : path.join(process.env.HOME || DATA_DIR, '.android'),
  UPLOAD_MAX_MB: parseInt(process.env.UPLOAD_MAX_MB || '2048', 10),
  SCAN_PORTS: (process.env.SCAN_PORTS || '5555')
    .split(',')
    .map((p) => parseInt(p.trim(), 10))
    .filter(Boolean),
  SUBNETS: process.env.SUBNETS ? process.env.SUBNETS.split(',') : [],
  ACCESS_TOKEN: process.env.ACCESS_TOKEN || '',
  ADB_BIN: process.env.ADB_BIN || 'adb',
  PULL_MAX_BYTES: parseInt(process.env.PULL_MAX_BYTES || '262144000', 10),
};

module.exports = config;
