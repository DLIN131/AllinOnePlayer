// 全部來源（順序 = 畫面上的順序）。每個來源的資料格式都一樣：
//   項目 { src, id, title, cover, sub, type: video|series|comic|actress, poster, lang }
//   連結 { src, title, params }（點了開某個列表；params.section = openSeries 時開劇集頁）
//   作品頁 { item, title, subtitle, cover, description, info[{label,text,links}], tags[連結], episodes, episodesTitle, chapters[{id,title}], related, url, pages, lang, extra }
import { eh, jm, nh, wn } from './sources/comics.js'
import { va } from './sources/va.js'
import { vb } from './sources/vb.js'
import { vc } from './sources/vc.js'

export const SOURCES = { va, vb, vc, nh, jm, wn, eh }
export const VIDEO_KEYS = ['va', 'vb', 'vc']
export const COMIC_KEYS = ['nh', 'jm', 'wn', 'eh']
export const MAIN_KEYS = [...VIDEO_KEYS, ...COMIC_KEYS]

/** 來源的標誌色 */
export const COLORS = { va: '#E11D48', vb: '#F472B6', vc: '#38BDF8', nh: '#ED2553', jm: '#FF8A00', wn: '#3D8BFD', eh: '#B5835A', local: '#94A3B8' }

export const src = (k) => SOURCES[k]
export const keyOf = (it) => `${it.src}_${it.id}`
